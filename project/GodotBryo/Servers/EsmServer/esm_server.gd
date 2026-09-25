@tool
extends Node

signal esm_ready
signal failed(message: String)
## A reference's current_cell_form_id changed because its space or position
## changed. Not emitted while a reference is being constructed.
signal reference_cell_changed(reference: EsmReference, old_cell_form_id: int, new_cell_form_id: int)

## Width of one exterior grid CELL in the unit of EsmReference.position:
## 4096 Gamebryo units at 70 units per metre (native/src/common/units.h).
const EXTERIOR_CELL_SIZE_METERS := 4096.0 / 70.0

const GameDataConfigScript := preload("res://game_data_config.gd")
const ResourceRoot := "res://GodotBryo/Types/Resource/"
const TYPE_TO_BASE := {
	"NPC_": "NpcBase", "RACE": "RaceBase", "HAIR": "HairBase", "EYES": "EyesBase",
	"CLAS": "ClassBase", "PACK": "PackageBase", "ARMO": "ArmorBase", "ARMA": "ArmorAddonBase",
	"FLST": "BipedModelListBase", "WEAP": "WeaponBase", "ALCH": "AlchemyBase", "LVLI": "LeveledItemBase",
	"AMMO": "AmmoBase", "BOOK": "BookBase", "CCRD": "CaravanCardBase", "CMNY": "CaravanMoneyBase",
	"KEYM": "KeyBase", "MISC": "MiscBase", "DOOR": "DoorBase", "SCOL": "StaticCollectionBase",
	"LIGH": "LightBase", "CONT": "ContainerBase", "ACTI": "ActivatorBase", "FURN": "FurnitureBase",
	"TACT": "TalkingActivatorBase", "MSTT": "MovableStaticBase", "TERM": "TerminalBase",
	"STAT": "StaticBase", "CREA": "CreatureBase", "BPTD": "BodyPartDataBase"
}
const TYPE_TO_REFERENCE := {
	"NPC_": "ActorReference", "CREA": "CreatureReference", "WEAP": "WeaponReference", "ARMO": "ArmorReference",
	"DOOR": "DoorReference", "SCOL": "StaticCollectionReference", "LIGH": "LightReference",
	"CONT": "ContainerReference", "ACTI": "ActivatorReference", "FURN": "FurnitureReference",
	"TACT": "TalkingActivatorReference", "ARMA": "ArmorAddonReference", "ALCH": "AlchemyReference",
	"LVLI": "LeveledItemReference", "AMMO": "AmmoReference", "BOOK": "BookReference",
	"CCRD": "CaravanCardReference", "CMNY": "CaravanMoneyReference", "KEYM": "KeyReference", "MISC": "MiscReference",
	"MSTT": "MovableStaticReference", "TERM": "TerminalReference", "STAT": "StaticReference"
}

var reader
var _cache: Dictionary = {}
# Authored placed references (REFR, ACHR, and ACRE) have stable identities
# for the lifetime of this server. Save loading must inject/replace its restored
# authored reference state here, rather than constructing parallel Resources.
var _authored_reference_cache: Dictionary = {}
var _placed_actor_placements: Array = []
var _xtel_door_placements: Array = []
var _placed_actor_instance_ids: PackedStringArray = PackedStringArray()
var _xtel_door_instance_ids: PackedStringArray = PackedStringArray()
var _placed_actor_ids_built := false
var _xtel_door_ids_built := false
var _record_index: Array = []
var _grid_cells: Dictionary = {} # WRLD -> {Vector2i(x, y) -> grid CELL}
var _persistent_cell_by_worldspace: Dictionary = {} # WRLD -> persistent CELL (0 if none)
var _worldspace_by_cell: Dictionary = {} # grid or persistent CELL -> WRLD
var _placed_reference_ids := PackedInt64Array() # sorted REFR/ACHR/ACRE FormIDs
var _placed_reference_cells := PackedInt64Array() # filing CELL, same order
var _reference_by_editor_id: Dictionary = {} # lowercased REFR/ACHR/ACRE EDID -> FormID
var _game_session = null
var _load_thread: Thread
var _load_result: Dictionary = {}
var state := "loading"
var _pending_rehydrates: Array[EsmBase] = []

func _ready() -> void:
	_load_thread = Thread.new()
	_load_thread.start(_open_reader_background)

## The load thread must be joined before this node goes away.
##
## _process() only collects it once it has already finished, so a session that
## quits while the ESM is still loading destroys a running Thread. That is not
## a tidiness warning: Godot aborts the process, after every test in the scene
## has passed. It is why short scenes exited 134 while long ones did not, and
## why which scenes failed moved between runs.
##
## wait_to_finish() blocks, and there is nothing to cancel -- the worker is a
## bounded read of FalloutNV.esm into memory -- so quitting mid-load waits for
## that read rather than crashing. The result is dropped: nothing can consume
## it at this point.
func _exit_tree() -> void:
	if _load_thread == null:
		return
	if _load_thread.is_started():
		_load_thread.wait_to_finish()
	_load_thread = null


func _process(_delta: float) -> void:
	if state != "loading" or _load_thread == null or _load_thread.is_alive():
		return
	_load_result = _load_thread.wait_to_finish()
	_load_thread = null
	if not bool(_load_result.get("ok", false)):
		state = "failed"
		failed.emit(String(_load_result.get("error", "ESM unavailable")))
		return
	reader = _load_result.get("reader")
	_record_index = _load_result.get("record_index", [])
	_grid_cells = _load_result.get("grid_cells", {})
	_persistent_cell_by_worldspace = _load_result.get("persistent_cell_by_worldspace", {})
	_worldspace_by_cell = _load_result.get("worldspace_by_cell", {})
	_placed_reference_ids = _load_result.get("placed_reference_ids", PackedInt64Array())
	_placed_reference_cells = _load_result.get("placed_reference_cells", PackedInt64Array())
	_reference_by_editor_id = _load_result.get("reference_by_editor_id", {})
	state = "ready"
	esm_ready.emit()
	for resource in _pending_rehydrates:
		rehydrate(resource)
	_pending_rehydrates.clear()

func _open_reader_background() -> Dictionary:
	var background_reader = ClassDB.instantiate("EsmReader")
	if background_reader == null:
		return {"ok": false, "error": "EsmReader class is unavailable"}
	var config := GameDataConfigScript.resolve()
	var path := String(config.get("data_dir", "")) + GameDataConfigScript.ESM_FILE
	if not background_reader.open(path):
		return {"ok": false, "error": background_reader.get_last_error()}
	var result := {"ok": true, "reader": background_reader, "record_index": background_reader.get_record_index()}
	result.merge(_build_cell_index(background_reader.get_exterior_cell_index()))
	result.merge(_build_reference_index(background_reader.get_placed_reference_cells(), result["record_index"]))
	return result

## Splits the native (reference, filing CELL) pairs into two sorted arrays for
## binary search, and maps placed-reference editor IDs to FormIDs.
static func _build_reference_index(pairs: PackedInt64Array, record_index: Array) -> Dictionary:
	var ids := PackedInt64Array()
	var cells := PackedInt64Array()
	ids.resize(pairs.size() / 2)
	cells.resize(pairs.size() / 2)
	for i in ids.size():
		ids[i] = pairs[i * 2]
		cells[i] = pairs[i * 2 + 1]
	var by_editor_id := {}
	for row: Dictionary in record_index:
		var record_type := String(row.get("record_type", ""))
		var editor_id := String(row.get("editor_id", ""))
		if not editor_id.is_empty() and (record_type == "REFR" or record_type == "ACHR" or record_type == "ACRE"):
			by_editor_id[editor_id.to_lower()] = int(row["form_id"])
	return {"placed_reference_ids": ids, "placed_reference_cells": cells, "reference_by_editor_id": by_editor_id}

## Turns the native per-worldspace cell listing into the lookup tables behind
## cell_at(), get_exterior_cell_form_id() and get_space_form_id_for_cell().
static func _build_cell_index(worldspaces: Array) -> Dictionary:
	var grid_cells := {}
	var persistent_cell_by_worldspace := {}
	var worldspace_by_cell := {}
	for world: Dictionary in worldspaces:
		var wrld := int(world.get("wrld_form_id", 0))
		var persistent := int(world.get("persistent_cell_form_id", 0))
		persistent_cell_by_worldspace[wrld] = persistent
		if persistent != 0:
			worldspace_by_cell[persistent] = wrld
		var cells := {}
		var grid: PackedInt64Array = world.get("grid", PackedInt64Array())
		for i in range(0, grid.size(), 3):
			cells[Vector2i(int(grid[i]), int(grid[i + 1]))] = int(grid[i + 2])
			worldspace_by_cell[int(grid[i + 2])] = wrld
		grid_cells[wrld] = cells
	return {
		"grid_cells": grid_cells,
		"persistent_cell_by_worldspace": persistent_cell_by_worldspace,
		"worldspace_by_cell": worldspace_by_cell,
	}

func is_ready() -> bool:
	return state == "ready"

func get_record_index() -> Array:
	return _record_index.duplicate()

func get_base(form_id: int) -> EsmBase:
	if form_id == 0 or reader == null:
		return null
	if _cache.has(form_id):
		return _cache[form_id]
	var raw: Dictionary = reader.get_record_data(form_id)
	if raw.is_empty():
		return null
	var type_tag := String(raw.get("record_type", ""))
	var script_name := String(TYPE_TO_BASE.get(type_tag, "EsmBase"))
	var script := load(ResourceRoot + _snake_case(script_name) + ".gd")
	if script == null:
		return null
	var result: EsmBase = script.new()
	_cache[form_id] = result
	# Publish before resolving links so recursive Base graphs still reuse this
	# exact Resource instance instead of constructing a duplicate.
	_populate_base(result, raw)
	return result

func get_base_from_uri(uri: String) -> EsmBase:
	var identity := _parse_source_uri(uri)
	if identity.is_empty() or reader == null:
		return null
	var raw: Dictionary = reader.get_record_data(int(identity.form_id))
	if raw.is_empty() or String(raw.get("record_type", "")) != identity.record_type:
		return null
	return get_base(int(identity.form_id))

func rehydrate(resource: EsmBase) -> bool:
	if resource == null:
		return false
	if not is_ready():
		if not _pending_rehydrates.has(resource):
			_pending_rehydrates.append(resource)
		return false
	if reader == null:
		return false
	var identity := _parse_source_uri(resource.source_uri)
	if identity.is_empty():
		return false
	var raw: Dictionary = reader.get_record_data(int(identity.form_id))
	if raw.is_empty() or String(raw.get("record_type", "")) != identity.record_type:
		return false
	resource._rehydrating = true
	_populate_base(resource, raw)
	resource._rehydrating = false
	return true

func get_base_type(form_id: int) -> Script:
	var raw: Dictionary = reader.get_record_data(form_id) if reader != null else {}
	if raw.is_empty():
		return null
	var name := String(TYPE_TO_BASE.get(String(raw.get("record_type", "")), "EsmBase"))
	return load(ResourceRoot + _snake_case(name) + ".gd")

func get_reference_type(refr_form_id: int) -> Script:
	var raw: Dictionary = reader.get_record_data(refr_form_id) if reader != null else {}
	if raw.is_empty():
		return null
	var base_id := _u32(_subrecord(raw, "NAME"))
	var base_raw: Dictionary = reader.get_record_data(base_id) if base_id != 0 else {}
	var name := String(TYPE_TO_REFERENCE.get(String(base_raw.get("record_type", "")), "EsmReference"))
	return load(ResourceRoot + _snake_case(name) + ".gd")

func get_reference(instance_id: String) -> EsmReference:
	if _game_session != null:
		return _game_session.get_reference(instance_id)
	if reader == null or not instance_id.begins_with("authored:"):
		if reader == null or not instance_id.begins_with("base:"):
			return null
		var base_form_id := _parse_prefixed_form_id(instance_id, "base:")
		return create_reference_for_base(base_form_id)
	if _authored_reference_cache.has(instance_id):
		return _authored_reference_cache[instance_id]
	var form_id := _parse_authored_id(instance_id)
	var cell_id := get_filing_cell_form_id(form_id)
	if cell_id == 0:
		return null
	var placement: Dictionary = reader.get_reference_placement(form_id)
	if placement.is_empty():
		return null
	return _reference_from_placement(placement, instance_id, cell_id)

## The placed reference with this editor ID, or null. Case-insensitive.
func find_reference_by_editor_id(editor_id: String) -> EsmReference:
	var form_id := int(_reference_by_editor_id.get(editor_id.to_lower(), 0))
	return get_reference("authored:%08X" % form_id) if form_id != 0 else null

## The CELL that files a placed REFR/ACHR/ACRE, or 0. In-memory lookup.
func get_filing_cell_form_id(refr_form_id: int) -> int:
	var i := _placed_reference_ids.bsearch(refr_form_id)
	if i < _placed_reference_ids.size() and _placed_reference_ids[i] == refr_form_id:
		return int(_placed_reference_cells[i])
	return 0

## Creates a zero-placement typed reference for inspecting a Base resource in
## the same physicalizer chain used by authored REFRs. The synthetic identity
## is persisted by EsmNode and can be rehydrated after a preview is packed.
func create_reference_for_base(base_form_id: int) -> EsmReference:
	var base := get_base(base_form_id)
	if base == null:
		return null
	var script_name := String(TYPE_TO_REFERENCE.get(base.record_type, "EsmReference"))
	var script := load(ResourceRoot + _snake_case(script_name) + ".gd")
	if script == null:
		return null
	var result: EsmReference = script.new()
	result.base_form_id = base.form_id
	result.base = base
	result.instance_id = "base:%08X" % base.form_id
	result.position = Vector3.ZERO
	result.rotation = Vector3.ZERO
	result.scale = 1.0
	_populate_reference_inventory(result)
	return result

## Creates a typed item reference for Inventory.restore_state(). Unlike a
## world reference it has no placement; its mutable item state is restored by
## Inventory from the save payload.
func create_inventory_item_reference(base_form_id: int, instance_id: String = "") -> EsmReference:
	var base := get_base(base_form_id)
	if base == null:
		return null
	var result := _create_inventory_item_reference(base, base_form_id, 0)
	if result != null and not instance_id.is_empty():
		result.instance_id = instance_id
	return result

func get_references_in_cell(cell_form_id: int) -> Array[EsmReference]:
	var result: Array[EsmReference] = []
	if reader == null:
		return result
	for placement in reader.get_cell_references(cell_form_id) + reader.get_cell_actors(cell_form_id):
		var reference := _reference_from_placement(placement, "authored:%08X" % int(placement.get("refr_form_id", 0)), cell_form_id)
		if reference != null:
			result.append(reference)
	return result

## Every authored ACHR represented by an ActorReference, regardless of which
## CELL/worldspace callers are currently loading. The returned objects are the
## canonical authored-reference cache instances.
func get_all_placed_actor_references() -> Array[ActorReference]:
	var result: Array[ActorReference] = []
	for placement in _get_placed_actor_placements():
		var reference := _reference_from_placement(
			placement,
			"authored:%08X" % int(placement.get("refr_form_id", 0)),
			int(placement.get("cell_form_id", 0))
		) as ActorReference
		if reference != null:
			result.append(reference)
	return result

## Stable authored IDs for all placed NPC ACHRs. This deliberately does no
## Resource construction, so a data-only consumer can resolve the canonical
## references incrementally without depending on streamer residency.
func get_all_placed_actor_instance_ids() -> PackedStringArray:
	if reader == null:
		return PackedStringArray()
	if _placed_actor_ids_built:
		return _placed_actor_instance_ids.duplicate()
	_placed_actor_ids_built = true
	for placement in _get_placed_actor_placements():
		_placed_actor_instance_ids.append("authored:%08X" % int(placement.get("refr_form_id", 0)))
	return _placed_actor_instance_ids.duplicate()

## Every placed DOOR REFR with an authored XTEL destination, independent of
## which CELL/worldspace callers currently have resident. These are canonical
## authored-reference cache instances.
func get_all_xtel_door_references() -> Array[DoorReference]:
	var result: Array[DoorReference] = []
	for placement in _get_xtel_door_placements():
		var reference := _reference_from_placement(
			placement,
			"authored:%08X" % int(placement.get("refr_form_id", 0)),
			int(placement.get("cell_form_id", 0))
		) as DoorReference
		if reference != null and reference.teleport != null:
			result.append(reference)
	return result

## Stable authored IDs for placed DOOR REFRs whose raw record has XTEL. The
## record scan remains ESM-facing; it neither asks a streamer for a resident
## population nor constructs any visual/physics content.
func get_all_xtel_door_instance_ids() -> PackedStringArray:
	if reader == null:
		return PackedStringArray()
	if _xtel_door_ids_built:
		return _xtel_door_instance_ids.duplicate()
	_xtel_door_ids_built = true
	for placement in _get_xtel_door_placements():
		_xtel_door_instance_ids.append("authored:%08X" % int(placement.get("refr_form_id", 0)))
	return _xtel_door_instance_ids.duplicate()

## Frame-sized construction access for data-only global consumers. Placement
## discovery happened in one native CELL census; each slice still goes through
## the canonical authored-reference cache.
func get_placed_actor_reference_batch(offset: int, limit: int) -> Array[ActorReference]:
	var result: Array[ActorReference] = []
	var placements := _get_placed_actor_placements()
	for index in range(offset, min(offset + limit, placements.size())):
		var placement: Dictionary = placements[index]
		var reference := _reference_from_placement(placement, "authored:%08X" % int(placement.get("refr_form_id", 0)), int(placement.get("cell_form_id", 0))) as ActorReference
		if reference != null:
			result.append(reference)
	return result

func get_xtel_door_reference_batch(offset: int, limit: int) -> Array[DoorReference]:
	var result: Array[DoorReference] = []
	var placements := _get_xtel_door_placements()
	for index in range(offset, min(offset + limit, placements.size())):
		var placement: Dictionary = placements[index]
		var reference := _reference_from_placement(placement, "authored:%08X" % int(placement.get("refr_form_id", 0)), int(placement.get("cell_form_id", 0))) as DoorReference
		if reference != null and reference.teleport != null:
			result.append(reference)
	return result

func _get_placed_actor_placements() -> Array:
	if not _placed_actor_placements.is_empty() or reader == null:
		return _placed_actor_placements
	if not reader.has_method("get_all_placed_npc_actors"):
		push_error("EsmServer requires a rebuilt EsmReader for placed NPC census")
		return _placed_actor_placements
	_placed_actor_placements = reader.get_all_placed_npc_actors()
	return _placed_actor_placements

func _get_xtel_door_placements() -> Array:
	if not _xtel_door_placements.is_empty() or reader == null:
		return _xtel_door_placements
	if not reader.has_method("get_all_xtel_doors"):
		push_error("EsmServer requires a rebuilt EsmReader for XTEL door census")
		return _xtel_door_placements
	_xtel_door_placements = reader.get_all_xtel_doors()
	return _xtel_door_placements

## Space of an authored reference without building it: the cached
## reference's own space, or the space of the CELL that files it.
func get_space_form_id_for_reference(instance_id: String) -> int:
	var cached: EsmReference = _authored_reference_cache.get(instance_id)
	if cached != null:
		return cached.current_space_form_id
	var cell := get_filing_cell_form_id(_parse_authored_id(instance_id))
	return get_space_form_id_for_cell(cell) if cell != 0 else 0

## The space a CELL belongs to: its WRLD for an exterior grid or persistent
## CELL, the CELL itself for an interior.
func get_space_form_id_for_cell(cell_form_id: int) -> int:
	return int(_worldspace_by_cell.get(cell_form_id, cell_form_id))

## Returns the exterior grid CELL at `coord`, or 0 where that worldspace has
## no CELL at that coordinate.
func get_exterior_cell_form_id(worldspace_form_id: int, coord: Vector2i) -> int:
	return int((_grid_cells.get(worldspace_form_id, {}) as Dictionary).get(coord, 0))

## Grid coordinate of an exterior position (metres, Gamebryo Z-up axes).
static func exterior_grid_coord(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x / EXTERIOR_CELL_SIZE_METERS), floori(position.y / EXTERIOR_CELL_SIZE_METERS))

## The CELL containing `position` in `space_form_id`. An interior space is a
## single CELL, returned as is. In a worldspace it is the grid CELL under the
## position, or the worldspace's persistent CELL where no grid CELL exists.
## In-memory lookups only; safe to call on every position write.
func cell_at(space_form_id: int, position: Vector3) -> int:
	if not _persistent_cell_by_worldspace.has(space_form_id):
		return space_form_id
	var cell := get_exterior_cell_form_id(space_form_id, exterior_grid_coord(position))
	return cell if cell != 0 else int(_persistent_cell_by_worldspace[space_form_id])

## Typed references for one exterior grid tile.
func get_references_in_exterior_cell(worldspace_form_id: int, coord: Vector2i) -> Array[EsmReference]:
	var cell_form_id := get_exterior_cell_form_id(worldspace_form_id, coord)
	return get_references_in_cell(cell_form_id) if cell_form_id != 0 else []

## Persistent exterior references belong to the worldspace rather than any
## individual grid tile, but use the same typed resource construction path.
func get_persistent_references_for_worldspace(worldspace_form_id: int) -> Array[EsmReference]:
	var result: Array[EsmReference] = []
	if reader == null:
		return result
	# These REFRs are filed in the worldspace's persistent CELL.
	var persistent_cell := int(_persistent_cell_by_worldspace.get(worldspace_form_id, 0))
	for placement in reader.get_persistent_refs_for_worldspace(worldspace_form_id):
		var reference := _reference_from_placement(
			placement,
			"authored:%08X" % int(placement.get("refr_form_id", 0)),
			persistent_cell
		)
		if reference != null:
			result.append(reference)
	return result

func _reference_from_placement(placement: Dictionary, id: String, cell_id: int) -> EsmReference:
	if _authored_reference_cache.has(id):
		return _authored_reference_cache[id]
	var type_tag := String(placement.get("base_type", ""))
	var name := String(TYPE_TO_REFERENCE.get(type_tag, "EsmReference"))
	var script = load(ResourceRoot + _snake_case(name) + ".gd")
	if script == null:
		return null
	var result: EsmReference = script.new()
	result.base_form_id = int(placement.get("base_form_id", 0))
	result.base = get_base(result.base_form_id)
	if result.base == null:
		return null
	result.instance_id = id
	result.set_location(get_space_form_id_for_cell(cell_id), placement.get("position", Vector3.ZERO), false)
	result.rotation = placement.get("rotation", Vector3.ZERO)
	result.scale = float(placement.get("scale", 1.0))
	result.visible_when_distant = bool(placement.get("visible_when_distant", false))
	result.has_xsrf_or_xsrd = bool(placement.get("has_xsrf_or_xsrd", false))
	_populate_reference_inventory(result)
	if result is ActorReference:
		var actor: ActorReference = result
		actor.spawn_cell_form_id = cell_id
		actor.simulation_mode = ActorReference.SimulationMode.LOW_LEVEL
	if result is DoorReference:
		var door_ref: DoorReference = result
		var ref_raw: Dictionary = reader.get_record_data(int(placement.get("refr_form_id", 0))) if reader != null else {}
		var destination_form_id := int(placement.get("dest_refr_form_id", 0))
		if bool(placement.get("has_xtel", false)) and destination_form_id != 0:
			var link := DoorTeleportLink.new()
			link.destination_id = "authored:%08X" % destination_form_id
			link.position = placement.get("dest_position", Vector3.ZERO)
			link.rotation = placement.get("dest_rotation", Vector3.ZERO)
			var xtel := _subrecord(ref_raw, "XTEL")
			link.no_alarm = xtel.size() >= 32 and (_u32(xtel, 28) & 0x01) != 0
			door_ref.teleport = link
		# XLOC presence means locked, at any level (level 0 is Very Easy).
		var lock_data := _subrecord(ref_raw, "XLOC")
		if lock_data.size() >= 9:
			door_ref.lock_level = _u8(lock_data)
			door_ref.lock_key_form_id = _u32(lock_data, 4)
			door_ref.lock_key = get_base(door_ref.lock_key_form_id) as KeyBase
			door_ref.lock_flags = _u8(lock_data, 8)
			door_ref.is_locked = true
			door_ref.is_leveled_lock = (door_ref.lock_flags & 0x04) != 0
		var activation := _subrecord(ref_raw, "XACT")
		if activation.size() >= 4:
			door_ref.activation_flags = _u32(activation)
		door_ref.is_open_by_default = _subrecord_present(ref_raw, "ONAM") or (door_ref.activation_flags & 0x08) != 0
		door_ref.is_open = door_ref.is_open_by_default
	if result is ActivatorReference or result is ContainerReference or result is FurnitureReference:
		var ref_raw: Dictionary = reader.get_record_data(int(placement.get("refr_form_id", 0))) if reader != null else {}
		var activation := _subrecord(ref_raw, "XACT")
		if result is ActivatorReference:
			(result as ActivatorReference).activation_flags = _u32(activation)
		elif result is ContainerReference:
			(result as ContainerReference).activation_flags = _u32(activation)
		else:
			(result as FurnitureReference).activation_flags = _u32(activation)
		if result is ContainerReference:
			result.is_open = false
	if result is StaticReference or result is MovableStaticReference:
		result.emittance_form_id = int(placement.get("emittance_form_id", 0))
	_authored_reference_cache[id] = result
	return result

## CNTO is the authored seed for an owner inventory. The live inventory is
## kept on the owner reference as typed item references and is not rebuilt
## from the base after the reference has been created.
func _populate_reference_inventory(reference: EsmReference) -> void:
	if not (reference is ActorReference or reference is CreatureReference or reference is ContainerReference):
		return
	var inventory := Inventory.new()
	reference.set("contents", inventory)
	var owner_base := reference.base
	if owner_base == null:
		return
	var item_index := 0
	var resolver := LeveledItemResolver.new(self)
	var level := int(reference.get("actor_level")) if reference.get("actor_level") != null else 1
	for item_data in owner_base.all_subrecord_data("CNTO"):
		if item_data.size() < 8:
			continue
		var item_form_id := _u32(item_data)
		var count := _i32(item_data, 4)
		var item_base := get_base(item_form_id)
		if item_base is LeveledItemBase:
			var resolved := resolver.resolve(item_base as LeveledItemBase, level, {"seed": owner_base.form_id ^ item_index})
			for resolved_item in resolved:
				resolved_item.instance_id = "inventory:%08X:%d" % [resolved_item.item_reference.base_form_id, item_index]
				if count > 1:
					resolved_item.count *= count
				reference.contents.add_inventory_item(resolved_item)
				item_index += 1
			continue
		var item_reference := _create_inventory_item_reference(item_base, item_form_id, item_index)
		if item_reference == null or count <= 0:
			item_index += 1
			continue
		var item := InventoryItem.new()
		item.item_reference = item_reference
		item.count = count
		item.instance_id = "inventory:%08X:%d" % [item_form_id, item_index]
		inventory.add_item(item)
		item_index += 1
	if reference is ActorReference:
		inventory.equip_default_armor()

func _create_inventory_item_reference(item_base: EsmBase, form_id: int, index: int) -> EsmReference:
	if item_base == null:
		return null
	var script_name := String(TYPE_TO_REFERENCE.get(item_base.record_type, "EsmReference"))
	var script := load(ResourceRoot + _snake_case(script_name) + ".gd")
	if script == null:
		return null
	var result: EsmReference = script.new()
	result.base_form_id = form_id
	result.base = item_base
	result.instance_id = "inventory-ref:%08X:%d" % [form_id, index]
	return result

func _populate_base(result: EsmBase, raw: Dictionary) -> void:
	result._rehydrating = true
	result.form_id = int(raw.get("form_id", 0))
	result.record_type = String(raw.get("record_type", ""))
	result.source_uri = "esm://FalloutNV.esm/%s/%08X" % [result.record_type, result.form_id]
	# A resource created from ESM gets the URI as its identity path. A
	# resource deserialized from a .tres must retain that file path; replacing
	# it would make Godot report a cyclic resource inclusion.
	if result.resource_path.is_empty() or result.resource_path.begins_with("esm://"):
		result.resource_path = result.source_uri
	result.raw_subrecords.clear()
	for subrecord in raw.get("subrecords", []):
		result.raw_subrecords.append(subrecord)
	result.editor_id = _string(_subrecord(raw, "EDID"))
	result.full_name = _string(_subrecord(raw, "FULL"))
	if result is LeveledItemBase:
		_populate_leveled_item(result as LeveledItemBase, raw)
	elif result is PackageBase:
		_populate_package(result as PackageBase, raw)
	elif result is WeaponBase:
		var weapon: WeaponBase = result
		weapon.model_path = _string(_subrecord(raw, "MODL"))
		var data := _subrecord(raw, "DATA")
		weapon.value = _i32(data); weapon.health = _i32(data, 4); weapon.weight = _f32(data, 8)
		weapon.base_damage = _u16(data, 12); weapon.clip_size = _u8(data, 14)
		weapon.first_person_form_id = _u32(_subrecord(raw, "WNAM"))
		weapon.equipment_type = _u32(_subrecord(raw, "ETYP")); weapon.animation_type = _u32(_subrecord(raw, "DNAM"))
		weapon.animation_family = _weapon_animation_family(weapon.animation_type)
		var weapon_dnam := _subrecord(raw, "DNAM")
		weapon.grip_animation = _u8(weapon_dnam, 13)
		weapon.reload_animation = _u8(weapon_dnam, 15)
		weapon.attack_animation = _u8(weapon_dnam, 41)
		weapon.biped_model_list_form_id = _u32(_subrecord(raw, "BIPL"))
		weapon.biped_model_list = get_base(weapon.biped_model_list_form_id) as BipedModelListBase
		var weapon_item_data: Dictionary = reader.get_item_data(result.form_id) if reader != null else {}
		weapon.inventory_icon = String(weapon_item_data.get("inventory_icon", ""))
		weapon.message_icon = String(weapon_item_data.get("message_icon", ""))
	elif result is MiscBase:
		var misc: MiscBase = result
		misc.model_path = _string(_subrecord(raw, "MODL"))
		var item_data: Dictionary = reader.get_item_data(result.form_id) if reader != null else {}
		misc.value = int(item_data.get("value", 0))
		misc.weight = float(item_data.get("weight", 0.0))
		misc.inventory_icon = String(item_data.get("inventory_icon", ""))
		misc.message_icon = String(item_data.get("message_icon", ""))
	elif result is AlchemyBase or result is AmmoBase or result is KeyBase:
		result.set("model_path", _string(_subrecord(raw, "MODL")))
		var generic_item_data: Dictionary = reader.get_item_data(result.form_id) if reader != null else {}
		result.set("value", int(generic_item_data.get("value", 0)))
		result.set("weight", float(generic_item_data.get("weight", 0.0)))
		result.set("inventory_icon", String(generic_item_data.get("inventory_icon", "")))
		result.set("message_icon", String(generic_item_data.get("message_icon", "")))
	elif result is NpcBase:
		var npc: NpcBase = result
		npc.model_path = _string(_subrecord(raw, "MODL"))
		var acbs := _subrecord(raw, "ACBS")
		npc.acbs_flags = _u32(acbs)
		npc.is_female = (npc.acbs_flags & 1) != 0
		npc.is_child = false
		var face := FaceGenData.new()
		face.fggs = _subrecord(raw, "FGGS")
		face.fgga = _subrecord(raw, "FGGA")
		face.fgts = _subrecord(raw, "FGTS")
		if reader != null and reader.has_method("get_facegen_data"):
			var decoded: Dictionary = reader.get_facegen_data(npc.form_id)
			face.fggs_values = decoded.get("fggs_values", PackedFloat32Array())
			face.fgga_values = decoded.get("fgga_values", PackedFloat32Array())
			face.fgts_values = decoded.get("fgts_values", PackedFloat32Array())
			face.fggs_decoded = bool(decoded.get("fggs_decoded", false))
			face.fgga_decoded = bool(decoded.get("fgga_decoded", false))
			face.fgts_decoded = bool(decoded.get("fgts_decoded", false))
			face.diagnostics = decoded.get("diagnostics", PackedStringArray())
		npc.face_gen = face
		npc.race_form_id = _u32(_subrecord(raw, "RNAM")); npc.race = get_base(npc.race_form_id) as RaceBase
		npc.hair_form_id = _u32(_subrecord(raw, "HNAM")); npc.hair = get_base(npc.hair_form_id) as HairBase
		npc.eyes_form_id = _u32(_subrecord(raw, "ENAM")); npc.eyes = get_base(npc.eyes_form_id) as EyesBase
		npc.class_form_id = _u32(_subrecord(raw, "CNAM")); npc.actor_class = get_base(npc.class_form_id) as ClassBase
		npc.body_part_data = get_base(NpcBase.DEFAULT_HUMAN_BODY_PART_DATA_FORM_ID) as BodyPartDataBase
		npc.packages.clear()
		for package_data in _all_subrecords(raw, "PKID"):
			var package_base := get_base(_u32(package_data)) as PackageBase
			if package_base != null: npc.packages.append(package_base)
	elif result is CreatureBase:
		_populate_creature(result as CreatureBase, raw)
	elif result is BodyPartDataBase:
		_populate_body_part_data(result as BodyPartDataBase, raw)
	elif result is RaceBase:
		_populate_race(result as RaceBase, raw)
	elif result is ArmorBase:
		var armor: ArmorBase = result
		armor.male_biped_model = _string(_subrecord(raw, "MODL")); armor.male_world_model = _string(_subrecord(raw, "MOD2"))
		armor.female_biped_model = _string(_subrecord(raw, "MOD3")); armor.female_world_model = _string(_subrecord(raw, "MOD4"))
		armor.model_path = armor.male_world_model
		armor.biped_flags = _u32(_subrecord(raw, "BMDT"))
		armor.equipment_type = _u32(_subrecord(raw, "ETYP"))
		var adata := _subrecord(raw, "DATA"); armor.value = _i32(adata); armor.weight = _f32(adata, 4); armor.armor_rating = _i32(_subrecord(raw, "DNAM"))
		armor.biped_model_list_form_id = _u32(_subrecord(raw, "BIPL"))
		armor.biped_model_list = get_base(armor.biped_model_list_form_id) as BipedModelListBase
	elif result is ArmorAddonBase:
		var addon: ArmorAddonBase = result
		addon.model_path = _string(_subrecord(raw, "MODL"))
		addon.male_biped_model = addon.model_path
		addon.female_biped_model = _string(_subrecord(raw, "MOD3"))
		addon.biped_flags = _u32(_subrecord(raw, "BMDT"))
	elif result is BipedModelListBase:
		var biped: BipedModelListBase = result
		biped.entries.clear()
		for addon_form_id_data in _all_subrecords(raw, "LNAM"):
			var addon_base := get_base(_u32(addon_form_id_data)) as ArmorAddonBase
			if addon_base != null: biped.entries.append(addon_base)
	elif result is DoorBase:
		var door: DoorBase = result
		door.model_path = _string(_subrecord(raw, "MODL"))
		door.script_form_id = _u32(_subrecord(raw, "SCRI"))
		door.open_sound_form_id = _u32(_subrecord(raw, "SNAM"))
		door.close_sound_form_id = _u32(_subrecord(raw, "ANAM"))
		door.loop_sound_form_id = _u32(_subrecord(raw, "BNAM"))
		var door_data: Dictionary = reader.get_door_data(door.form_id) if reader != null else {}
		door.open_sound_path = String(door_data.get("open_sound_path", ""))
		door.close_sound_path = String(door_data.get("close_sound_path", ""))
		door.loop_sound_path = String(door_data.get("loop_sound_path", ""))
		door.flags = int(door_data.get("flags", _u8(_subrecord(raw, "FNAM"))))
		door.is_automatic_door = bool(door_data.get("is_automatic_door", false))
		door.is_hidden = bool(door_data.get("is_hidden", false))
		door.is_minimal_use = bool(door_data.get("is_minimal_use", false))
		door.is_sliding_door = bool(door_data.get("is_sliding_door", false))
	elif result is LightBase:
		var light: LightBase = result
		light.model_path = _string(_subrecord(raw, "MODL"))
		light.script_form_id = _u32(_subrecord(raw, "SCRI"))
		light.icon_path = _string(_subrecord(raw, "ICON"))
		light.small_icon_path = _string(_subrecord(raw, "MICO"))
		light.fade_value = _f32(_subrecord(raw, "FMAM"))
		light.sound_form_id = _u32(_subrecord(raw, "SNAM"))
		var light_data: Dictionary = reader.get_light_data(light.form_id) if reader != null else {}
		light.time = int(light_data.get("time", _i32(_subrecord(raw, "DATA"))))
		light.radius = float(light_data.get("radius", 0.0))
		light.color = light_data.get("color", Color.WHITE)
		light.flags = int(light_data.get("flags", 0))
		light.falloff_exponent = float(light_data.get("falloff", 1.0))
		light.fov_degrees = float(light_data.get("fov_degrees", 90.0))
		light.value = int(light_data.get("value", 0))
		light.weight = float(light_data.get("weight", 0.0))
		light.is_dynamic = (light.flags & 0x01) != 0
		light.can_be_carried = (light.flags & 0x02) != 0
		light.is_negative = (light.flags & 0x04) != 0
		light.flickers = (light.flags & 0x08) != 0
		light.is_off_by_default = (light.flags & 0x20) != 0
		light.flickers_slowly = (light.flags & 0x40) != 0
		light.pulses = (light.flags & 0x80) != 0
		light.pulses_slowly = (light.flags & 0x100) != 0
		light.is_spot_light = (light.flags & 0x200) != 0
		light.casts_spot_shadows = (light.flags & 0x400) != 0
	elif result is ActivatorBase:
		var activator: ActivatorBase = result
		activator.model_path = _string(_subrecord(raw, "MODL"))
		activator.script_form_id = _u32(_subrecord(raw, "SCRI"))
		activator.looping_sound_form_id = _u32(_subrecord(raw, "SNAM"))
		activator.activation_sound_form_id = _u32(_subrecord(raw, "VNAM"))
		activator.radio_template_form_id = _u32(_subrecord(raw, "INAM"))
		activator.radio_station_form_id = _u32(_subrecord(raw, "RNAM"))
		activator.water_type_form_id = _u32(_subrecord(raw, "WNAM"))
		activator.activation_prompt = _string(_subrecord(raw, "XATO"))
		activator.looping_sound_path = _sound_path(activator.looping_sound_form_id)
		activator.activation_sound_path = _sound_path(activator.activation_sound_form_id)
	elif result is ContainerBase:
		var container: ContainerBase = result
		container.model_path = _string(_subrecord(raw, "MODL"))
		container.script_form_id = _u32(_subrecord(raw, "SCRI"))
		var container_data := _subrecord(raw, "DATA")
		container.flags = _u8(container_data)
		container.weight = _f32(container_data, 1)
		container.open_sound_form_id = _u32(_subrecord(raw, "SNAM"))
		container.close_sound_form_id = _u32(_subrecord(raw, "QNAM"))
		container.random_sound_form_id = _u32(_subrecord(raw, "RNAM"))
		container.open_sound_path = _sound_path(container.open_sound_form_id)
		container.close_sound_path = _sound_path(container.close_sound_form_id)
		container.random_sound_path = _sound_path(container.random_sound_form_id)
	elif result is FurnitureBase:
		var furniture: FurnitureBase = result
		furniture.model_path = _string(_subrecord(raw, "MODL"))
		furniture.script_form_id = _u32(_subrecord(raw, "SCRI"))
		furniture.marker_flags = _subrecord(raw, "MNAM")
	elif result is BookBase or result is CaravanCardBase or result is CaravanMoneyBase:
		result.set("model_path", _string(_subrecord(raw, "MODL")))
	elif result is TalkingActivatorBase:
		var talking_activator: TalkingActivatorBase = result
		talking_activator.model_path = _string(_subrecord(raw, "MODL"))
		talking_activator.script_form_id = _u32(_subrecord(raw, "SCRI"))
		talking_activator.voice_type_form_id = _u32(_subrecord(raw, "VNAM"))
		talking_activator.sound_form_id = _u32(_subrecord(raw, "SNAM"))
		talking_activator.sound_path = _sound_path(talking_activator.sound_form_id)
	elif result is TerminalBase:
		var terminal: TerminalBase = result
		terminal.model_path = _string(_subrecord(raw, "MODL"))
		terminal.script_form_id = _u32(_subrecord(raw, "SCRI"))
		terminal.welcome_text = _string(_subrecord(raw, "DESC"))
		terminal.looping_sound_form_id = _u32(_subrecord(raw, "SNAM"))
		terminal.looping_sound_path = _sound_path(terminal.looping_sound_form_id)
		terminal.password_note_form_id = _u32(_subrecord(raw, "PNAM"))
		var terminal_data := _subrecord(raw, "DNAM")
		terminal.hacking_difficulty = _u8(terminal_data)
		terminal.flags = _u8(terminal_data, 1)
		terminal.server_type = _u8(terminal_data, 2)
		terminal.is_leveled = (terminal.flags & 0x01) != 0
		terminal.is_unlocked = (terminal.flags & 0x02) != 0
		terminal.uses_alternate_colors = (terminal.flags & 0x04) != 0
		terminal.hides_welcome_text = (terminal.flags & 0x08) != 0
		terminal.menu_items.clear()
		if reader != null:
			var parsed_terminal: Dictionary = reader.get_terminal_data(terminal.form_id)
			for item_data in parsed_terminal.get("items", []):
				var item := TerminalMenuItem.new()
				item.text = String(item_data.get("text", ""))
				item.result_text = String(item_data.get("result_text", ""))
				item.item_flags = int(item_data.get("flags", 0))
				item.display_note_form_id = int(item_data.get("note_form_id", 0))
				item.submenu_terminal_form_id = int(item_data.get("submenu_form_id", 0))
				item.condition_count = int(item_data.get("condition_count", 0))
				item.script_source = String(item_data.get("script_source", ""))
				terminal.menu_items.append(item)
	else:
		if _has_property(result, "model_path"):
			result.set("model_path", _string(_subrecord(raw, "MODL")))
	result._rehydrating = false

func _populate_race(race: RaceBase, raw: Dictionary) -> void:
	# These relationship fields are documented by fopdoc as formid/formid[],
	# while the appearance collections are the native parser's verified
	# marker-delimited RACE interpretation.
	race.older_race_form_id = _u32(_subrecord(raw, "ONAM"))
	race.younger_race_form_id = _u32(_subrecord(raw, "YNAM"))
	race.hair_form_ids = _form_ids(raw, "HNAM")
	race.eyes_form_ids = _form_ids(raw, "ENAM")
	race.hairs.clear()
	for form_id in race.hair_form_ids:
		var hair := get_base(form_id) as HairBase
		if hair != null: race.hairs.append(hair)
	race.eyes.clear()
	for form_id in race.eyes_form_ids:
		var eyes := get_base(form_id) as EyesBase
		if eyes != null: race.eyes.append(eyes)

	var voices := _subrecord(raw, "VTCK")
	if voices.size() >= 8:
		race.male_voice_form_id = _u32(voices)
		race.female_voice_form_id = _u32(voices, 4)
	var default_hair := _subrecord(raw, "DNAM")
	if default_hair.size() >= 8:
		race.male_default_hair = get_base(_u32(default_hair)) as HairBase
		race.female_default_hair = get_base(_u32(default_hair, 4)) as HairBase
	var colors := _subrecord(raw, "CNAM")
	if colors.size() >= 2:
		race.male_default_hair_color = _u8(colors)
		race.female_default_hair_color = _u8(colors, 1)
	var data := _subrecord(raw, "DATA")
	if data.size() >= 36:
		race.male_height = _f32(data, 16)
		race.female_height = _f32(data, 20)
		race.male_weight = _f32(data, 24)
		race.female_weight = _f32(data, 28)
		race.flags = _u32(data, 32)
	race.facegen_main_clamp = _f32(_subrecord(raw, "PNAM"))
	race.facegen_face_clamp = _f32(_subrecord(raw, "UNAM"))

	for female in [false, true]:
		var body_parts: Array = reader.get_race_body_parts(race.form_id, female)
		for item in body_parts:
			var body := RacePartBaseResource.new()
			body.index = int(item.get("index", 0))
			body.part_type = _race_body_part_type(body.index)
			body.model_path = String(item.get("model", ""))
			body.icon_path = String(item.get("icon", ""))
			if female: race.female_body_parts.append(body)
			else: race.male_body_parts.append(body)
		var head_parts: Array = reader.get_race_head_parts(race.form_id, female)
		for item in head_parts:
			var head := RacePartBaseResource.new()
			head.index = int(item.get("index", 0))
			head.part_type = _race_head_part_type(head.index)
			head.model_path = String(item.get("model", ""))
			head.icon_path = String(item.get("icon", ""))
			if female: race.female_head_parts.append(head)
			else: race.male_head_parts.append(head)

func _form_ids(raw: Dictionary, tag: String) -> Array[int]:
	var result: Array[int] = []
	for data in _all_subrecords(raw, tag):
		for offset in range(0, data.size() - 3, 4):
			result.append(_u32(data, offset))
	return result

func _race_head_part_type(index: int) -> String:
	return ["head", "ears", "mouth", "teeth_lower", "teeth_upper", "tongue", "eye_left", "eye_right"][index] if index >= 0 and index < 8 else "unknown_%d" % index

func _race_body_part_type(index: int) -> String:
	return ["upper_body", "left_hand", "right_hand", "upper_body_texture"][index] if index >= 0 and index < 4 else "unknown_%d" % index

func _weapon_animation_family(animation_type: int) -> String:
	return {
		0: "h2h", 1: "1hm", 2: "2hm", 3: "1hp", 4: "1hp", 5: "2hr",
		6: "2ha", 7: "2hr", 8: "2hh", 9: "2hl", 10: "1gt",
		11: "1lm", 12: "1md", 13: "1gt"
	}.get(animation_type, "")

func _subrecord(raw: Dictionary, tag: String) -> PackedByteArray:
	for subrecord in raw.get("subrecords", []):
		if String(subrecord.get("type", "")) == tag:
			return subrecord.get("data", PackedByteArray())
	return PackedByteArray()

func _subrecord_present(raw: Dictionary, tag: String) -> bool:
	for subrecord in raw.get("subrecords", []):
		if String(subrecord.get("type", "")) == tag:
			return true
	return false

func _all_subrecords(raw: Dictionary, tag: String) -> Array[PackedByteArray]:
	var result: Array[PackedByteArray] = []
	for subrecord in raw.get("subrecords", []):
		if String(subrecord.get("type", "")) == tag:
			result.append(subrecord.get("data", PackedByteArray()))
	return result

func _populate_leveled_item(result: LeveledItemBase, raw: Dictionary) -> void:
	result.chance_none = _u8(_subrecord(raw, "LVLD"))
	result.flags = _u8(_subrecord(raw, "LVLF"))
	result.global_form_id = _u32(_subrecord(raw, "LVLG"))
	result.entries.clear()
	var subrecords: Array = raw.get("subrecords", [])
	for index in subrecords.size():
		var sub: Dictionary = subrecords[index]
		if String(sub.get("type", "")) != "LVLO":
			continue
		var data: PackedByteArray = sub.get("data", PackedByteArray())
		if data.size() < 8:
			result.diagnostics.append("LVLI 0x%08X has truncated LVLO at %d" % [result.form_id, index])
			continue
		var entry := LeveledItemEntry.new()
		entry.level = _i16(data)
		if data.size() >= 12:
			entry.item_form_id = _u32(data, 4)
			entry.count = _i16(data, 8)
		elif data.size() >= 8:
			# Older records omit the two unknown words around the FormID.
			entry.item_form_id = _u32(data, 2)
			entry.count = _i16(data, 6)
		entry.item_base = get_base(entry.item_form_id)
		if data.size() != 12 and data.size() != 8:
			result.diagnostics.append("LVLI 0x%08X has non-standard LVLO size %d" % [result.form_id, data.size()])
		if index + 1 < subrecords.size() and String(subrecords[index + 1].get("type", "")) == "COED":
			var extra: PackedByteArray = subrecords[index + 1].get("data", PackedByteArray())
			entry.raw_extra_data = extra
			if extra.size() >= 4:
				entry.owner_form_id = _u32(extra)
			if extra.size() >= 12:
				entry.health_percent = _f32(extra, 8)
		result.entries.append(entry)

## Populate Fallout New Vegas's PACK record using xEdit's FNV schema
## (`enginedocs/xEdit/Core/wbDefinitionsFNV.pas`). The local GECK pages
## `Packages/Category_Packages` and `Packages/How Are Packages Evaluated`
## document the resulting schedule/condition/ordered-selection semantics.
## OpenMW's ESM4 PACK reader was checked as a secondary comparison, but it
## explicitly labels its Fallout branches FIXME, so it is not used as format
## authority. The shipped master has both 12-byte FNV and 8-byte legacy PKDT
## forms, plus 20- and 28-byte CTDA forms; preserve and decode both rather
## than treating either as malformed.
func _populate_package(result: PackageBase, raw: Dictionary) -> void:
	result.general_flags_raw = 0
	result.general_flags = null
	result.package_type = PackageBase.PackageType.FIND
	result.fallout_behavior_flags_raw = 0
	result.fallout_behavior_flags = null
	result.type_specific_flags_raw = 0
	result.type_specific_flags = null
	result.location_1 = null
	result.location_2 = null
	result.schedule = null
	result.target_1 = null
	result.target_2 = null
	result.conditions.clear()
	result.idle_animation_form_ids.clear()
	result.idle_collection_chance_raw = PackedByteArray()
	result.idle_collection_flags_raw = PackedByteArray()
	result.idle_collection_timer_raw = PackedByteArray()
	result.combat_style_form_id = 0
	result.has_eat_marker = false
	result.escort_distance = 0
	result.follow_start_location_trigger_radius = 0.0
	result.patrol_repeatable = true
	result.use_weapon_data = null
	result.has_use_item_marker = false
	result.has_ambush_marker = false
	result.dialogue_data = null
	result.on_begin = null
	result.on_end = null
	result.on_change = null

	var current_event: PackageEvent = null
	for subrecord in raw.get("subrecords", []):
		var tag := String(subrecord.get("type", ""))
		var data: PackedByteArray = subrecord.get("data", PackedByteArray())
		match tag:
			"PKDT":
				_populate_package_general(result, data)
			"PLDT":
				result.location_1 = _package_location(result, "PLDT", data)
			"PLD2":
				result.location_2 = _package_location(result, "PLD2", data)
			"PSDT":
				result.schedule = _package_schedule(result, data)
			"PTDT":
				result.target_1 = _package_target(result, "PTDT", data)
			"PTD2":
				result.target_2 = _package_target(result, "PTD2", data)
			"CTDA":
				var condition := _package_condition(result, data)
				if condition != null:
					result.conditions.append(condition)
			"IDLA":
				for offset in range(0, data.size() - 3, 4):
					result.idle_animation_form_ids.append(_u32(data, offset))
			"IDLC":
				result.idle_collection_chance_raw = data.duplicate()
			"IDLF":
				result.idle_collection_flags_raw = data.duplicate()
			"IDLT":
				result.idle_collection_timer_raw = data.duplicate()
			"CNAM":
				result.combat_style_form_id = _u32(data)
			"PKED":
				result.has_eat_marker = true
			"PKE2":
				result.escort_distance = _u32(data)
			"PKFD":
				result.follow_start_location_trigger_radius = _f32(data)
			"PKPT":
				result.patrol_repeatable = _u8(data) != 0
			"PKW3":
				result.use_weapon_data = _package_use_weapon_data(result, data)
			"PUID":
				result.has_use_item_marker = true
			"PKAM":
				result.has_ambush_marker = true
			"PKDD":
				result.dialogue_data = _package_dialogue_data(result, data)
			"POBA":
				current_event = PackageEvent.new()
				result.on_begin = current_event
			"POEA":
				current_event = PackageEvent.new()
				result.on_end = current_event
			"POCA":
				current_event = PackageEvent.new()
				result.on_change = current_event
			_:
				if current_event != null:
					_populate_package_event_subrecord(current_event, tag, data)

func _populate_package_general(result: PackageBase, data: PackedByteArray) -> void:
	if data.size() != 8 and data.size() != 12:
		result.diagnostics.append("PACK 0x%08X has PKDT with %d bytes; expected 8 or 12" % [result.form_id, data.size()])
		return
	result.general_flags_raw = _u32(data)
	result.general_flags = _decode_package_general_flags(result.general_flags_raw)
	# Both forms encode the package type at offset four. The 12-byte FNV form
	# then carries a padding byte, Fallout Behavior flags, type-specific flags,
	# and two final unused bytes.
	result.package_type = _u8(data, 4)
	if data.size() == 12:
		result.fallout_behavior_flags_raw = _u16(data, 6)
		result.type_specific_flags_raw = _u16(data, 8)
		result.fallout_behavior_flags = _decode_package_fallout_behavior_flags(result.fallout_behavior_flags_raw)
		result.type_specific_flags = _decode_package_type_specific_flags(result.package_type, result.type_specific_flags_raw)
	else:
		result.fallout_behavior_flags = _decode_package_fallout_behavior_flags(0)
		result.type_specific_flags = _decode_package_type_specific_flags(result.package_type, 0)

func _decode_package_general_flags(raw_flags: int) -> PackageGeneralFlags:
	var result := PackageGeneralFlags.new()
	result.offers_services = (raw_flags & 0x00000001) != 0
	result.must_reach_location = (raw_flags & 0x00000002) != 0
	result.must_complete = (raw_flags & 0x00000004) != 0
	result.lock_doors_at_package_start = (raw_flags & 0x00000008) != 0
	result.lock_doors_at_package_end = (raw_flags & 0x00000010) != 0
	result.lock_doors_at_location = (raw_flags & 0x00000020) != 0
	result.unlock_doors_at_package_start = (raw_flags & 0x00000040) != 0
	result.unlock_doors_at_package_end = (raw_flags & 0x00000080) != 0
	result.unlock_doors_at_location = (raw_flags & 0x00000100) != 0
	result.continue_if_player_near = (raw_flags & 0x00000200) != 0
	result.once_per_day = (raw_flags & 0x00000400) != 0
	result.skip_fallout_behavior = (raw_flags & 0x00001000) != 0
	result.always_run = (raw_flags & 0x00002000) != 0
	result.always_sneak = (raw_flags & 0x00020000) != 0
	result.allow_swimming = (raw_flags & 0x00040000) != 0
	result.allow_falls = (raw_flags & 0x00080000) != 0
	result.head_tracking_off = (raw_flags & 0x00100000) != 0
	result.weapons_unequipped = (raw_flags & 0x00200000) != 0
	result.defensive_combat = (raw_flags & 0x00400000) != 0
	result.weapon_drawn = (raw_flags & 0x00800000) != 0
	result.no_idle_animations = (raw_flags & 0x01000000) != 0
	result.pretend_in_combat = (raw_flags & 0x02000000) != 0
	result.continue_during_combat = (raw_flags & 0x04000000) != 0
	result.no_combat_alert = (raw_flags & 0x08000000) != 0
	result.no_warn_or_attack_behavior = (raw_flags & 0x10000000) != 0
	var known_mask := 0x1FFFFFFF & ~0x0001C800
	result.unknown_mask = raw_flags & ~known_mask
	return result

func _decode_package_fallout_behavior_flags(raw_flags: int) -> PackageFalloutBehaviorFlags:
	var result := PackageFalloutBehaviorFlags.new()
	result.hellos_to_player = (raw_flags & 0x0001) != 0
	result.random_conversations = (raw_flags & 0x0002) != 0
	result.observe_combat_behavior = (raw_flags & 0x0004) != 0
	result.reaction_to_player_actions = (raw_flags & 0x0010) != 0
	result.friendly_fire_comments = (raw_flags & 0x0020) != 0
	result.aggro_radius_behavior = (raw_flags & 0x0040) != 0
	result.allow_idle_chatter = (raw_flags & 0x0080) != 0
	result.avoid_radiation = (raw_flags & 0x0100) != 0
	result.unknown_mask = raw_flags & ~0x0177
	return result

func _decode_package_type_specific_flags(package_type: int, raw_flags: int) -> PackageTypeSpecificFlags:
	var result := PackageTypeSpecificFlags.new()
	var known_mask := 0
	match package_type:
		PackageBase.PackageType.FIND, PackageBase.PackageType.ESCORT, PackageBase.PackageType.EAT:
			result.allow_buying = (raw_flags & 0x0100) != 0
			result.allow_killing = (raw_flags & 0x0200) != 0
			result.allow_stealing = (raw_flags & 0x0400) != 0
			known_mask = 0x0700
		PackageBase.PackageType.WANDER, PackageBase.PackageType.SANDBOX:
			result.no_eating = (raw_flags & 0x0001) != 0
			result.no_sleeping = (raw_flags & 0x0002) != 0
			result.no_conversation = (raw_flags & 0x0004) != 0
			result.no_idle_markers = (raw_flags & 0x0008) != 0
			result.no_furniture = (raw_flags & 0x0010) != 0
			result.no_wandering = (raw_flags & 0x0020) != 0
			known_mask = 0x003F
		PackageBase.PackageType.USE_ITEM_AT:
			result.sit_down = (raw_flags & 0x0004) != 0
			result.allow_buying = (raw_flags & 0x0100) != 0
			result.allow_killing = (raw_flags & 0x0200) != 0
			result.allow_stealing = (raw_flags & 0x0400) != 0
			known_mask = 0x0704
		PackageBase.PackageType.AMBUSH:
			result.hide_while_ambushing = (raw_flags & 0x0001) != 0
			known_mask = 0x0001
		PackageBase.PackageType.GUARD:
			result.remain_near_reference_to_guard = (raw_flags & 0x0008) != 0
			known_mask = 0x0008
	result.unknown_mask = raw_flags & ~known_mask
	return result

func _package_location(owner: PackageBase, tag: String, data: PackedByteArray) -> PackageLocation:
	if data.size() != 12:
		owner.diagnostics.append("PACK 0x%08X has %s with %d bytes; expected 12" % [owner.form_id, tag, data.size()])
		return null
	var location := PackageLocation.new()
	location.location_type = _i32(data)
	location.location_value = _decode_package_location_value(location.location_type, _u32(data, 4))
	location.radius = _i32(data, 8)
	return location

func _decode_package_location_value(location_type: PackageLocation.LocationType, raw_value: int) -> PackageLocationValue:
	var result := PackageLocationValue.new()
	result.raw_value = raw_value
	match location_type:
		PackageLocation.LocationType.NEAR_REFERENCE:
			result.value_kind = PackageLocationValue.ValueKind.REFERENCE
			result.reference_instance_id = "authored:%08X" % raw_value
		PackageLocation.LocationType.IN_CELL:
			result.value_kind = PackageLocationValue.ValueKind.CELL
			result.cell_form_id = raw_value
		PackageLocation.LocationType.NEAR_CURRENT_LOCATION:
			result.value_kind = PackageLocationValue.ValueKind.CURRENT_LOCATION
		PackageLocation.LocationType.NEAR_EDITOR_LOCATION:
			result.value_kind = PackageLocationValue.ValueKind.EDITOR_LOCATION
		PackageLocation.LocationType.OBJECT_ID:
			result.value_kind = PackageLocationValue.ValueKind.OBJECT_BASE
			result.object_base_form_id = raw_value
		PackageLocation.LocationType.OBJECT_TYPE:
			result.value_kind = PackageLocationValue.ValueKind.OBJECT_TYPE
			result.object_type = raw_value
		PackageLocation.LocationType.NEAR_LINKED_REFERENCE:
			result.value_kind = PackageLocationValue.ValueKind.LINKED_REFERENCE
		PackageLocation.LocationType.AT_PACKAGE_LOCATION:
			result.value_kind = PackageLocationValue.ValueKind.PACKAGE_LOCATION
	return result

func _package_schedule(owner: PackageBase, data: PackedByteArray) -> PackageSchedule:
	if data.size() != 8:
		owner.diagnostics.append("PACK 0x%08X has PSDT with %d bytes; expected 8" % [owner.form_id, data.size()])
		return null
	var schedule := PackageSchedule.new()
	schedule.month = _i8(data)
	schedule.day_of_week = _i8(data, 1)
	schedule.date = _i8(data, 2)
	schedule.time = _i8(data, 3)
	schedule.duration_hours = _u32(data, 4)
	return schedule

func _package_target(owner: PackageBase, tag: String, data: PackedByteArray) -> PackageTarget:
	if data.size() != 16:
		owner.diagnostics.append("PACK 0x%08X has %s with %d bytes; expected 16" % [owner.form_id, tag, data.size()])
		return null
	var target := PackageTarget.new()
	target.target_type = _i32(data)
	target.target_value = _u32(data, 4)
	target.count_or_distance = _i32(data, 8)
	target.unknown = _f32(data, 12)
	return target

func _package_condition(owner: PackageBase, data: PackedByteArray) -> PackageCondition:
	if data.size() != 20 and data.size() != 28:
		owner.diagnostics.append("PACK 0x%08X has CTDA with %d bytes; expected 20 or 28" % [owner.form_id, data.size()])
		return null
	var condition := PackageCondition.new()
	condition.type_flags = _u8(data)
	condition.comparison_value = _f32(data, 4)
	# The Condition Type bit which changes the comparison word into a GLOB
	# FormID is xEdit's CTDA comparison-value union discriminator.
	if (condition.type_flags & 0x04) != 0:
		condition.comparison_global_form_id = _u32(data, 4)
	condition.function_id = _u16(data, 8)
	condition.parameter_1 = _u32(data, 12)
	condition.parameter_2 = _u32(data, 16)
	if data.size() == 28:
		condition.has_run_on = true
		condition.run_on = _u32(data, 20)
		condition.reference_form_id = _u32(data, 24)
	return condition

func _package_use_weapon_data(owner: PackageBase, data: PackedByteArray) -> PackageUseWeaponData:
	if data.size() != 24:
		owner.diagnostics.append("PACK 0x%08X has PKW3 with %d bytes; expected 24" % [owner.form_id, data.size()])
		return null
	var result := PackageUseWeaponData.new()
	result.flags = _u32(data)
	result.always_hit = (result.flags & 0x00000001) != 0
	result.does_no_damage = (result.flags & 0x00000100) != 0
	result.crouch_to_reload = (result.flags & 0x00010000) != 0
	result.hold_fire_when_blocked = (result.flags & 0x01000000) != 0
	result.fire_rate = _u8(data, 4)
	result.fire_count = _u8(data, 5)
	result.burst_count = _u16(data, 6)
	result.shots_per_volley_min = _u16(data, 8)
	result.shots_per_volley_max = _u16(data, 10)
	result.pause_between_volleys_min = _f32(data, 12)
	result.pause_between_volleys_max = _f32(data, 16)
	return result

func _package_dialogue_data(owner: PackageBase, data: PackedByteArray) -> PackageDialogueData:
	if data.size() != 24:
		owner.diagnostics.append("PACK 0x%08X has PKDD with %d bytes; expected 24" % [owner.form_id, data.size()])
		return null
	var result := PackageDialogueData.new()
	result.field_of_view = _f32(data)
	result.topic_form_id = _u32(data, 4)
	result.flags = _u32(data, 8)
	result.no_headtracking = (result.flags & 0x00000001) != 0
	result.does_not_control_target_movement = (result.flags & 0x00000100) != 0
	result.dialogue_type = _u32(data, 16)
	result.unknown = _u32(data, 20)
	return result

func _populate_package_event_subrecord(event: PackageEvent, tag: String, data: PackedByteArray) -> void:
	match tag:
		"INAM": event.idle_form_id = _u32(data)
		"TNAM": event.topic_form_id = _u32(data)
		"SCHR":
			event.script_header = data.duplicate()
			event.script_reference_count = _u32(data, 4)
			event.compiled_script_size = _u32(data, 8)
			event.script_variable_count = _u32(data, 12)
			event.script_type = _u16(data, 16)
			event.script_flags = _u16(data, 18)
		"SCDA": event.compiled_script = data.duplicate()
		"SCTX": event.script_source = _string(data)
		"SLSD":
			event.local_variable_data.append(data.duplicate())
			var local := PackageScriptLocal.new()
			local.index = _u32(data)
			local.variable_type = _u8(data, 16)
			local.raw_data = data.duplicate()
			event.local_variables.append(local)
		"SCVR":
			var name := _string(data)
			event.local_variable_names.append(name)
			if not event.local_variables.is_empty():
				event.local_variables.back().name = name
		"SCRO": event.script_references.append(_u32(data))
		"SCRV": event.script_local_reference_indices.append(_u32(data))

func _populate_creature(result: CreatureBase, raw: Dictionary) -> void:
	result.model_path = _string(_subrecord(raw, "MODL"))
	result.model_list_filenames.clear()
	result.model_list_paths.clear()
	result.animation_filenames.clear()
	result.animation_paths.clear()
	result.pnam_values.clear()
	# Bethesda asset paths are commonly stored with backslashes. Normalize only
	# while extracting the directory; the resolved values retain the project's
	# established backslash path convention.
	var model_directory := result.model_path.replace("\\", "/").get_base_dir()
	for data in _all_subrecords(raw, "NIFZ"):
		for filename in _zero_terminated_strings(data):
			result.model_list_filenames.append(filename)
			result.model_list_paths.append(_join_creature_asset_path(model_directory, filename))
	for data in _all_subrecords(raw, "KFFZ"):
		for filename in _zero_terminated_strings(data):
			result.animation_filenames.append(filename)
			result.animation_paths.append(_join_creature_asset_path(model_directory, filename))
	for data in _all_subrecords(raw, "PNAM"):
		if data.size() >= 4:
			result.pnam_values.append(_u32(data))

func _populate_body_part_data(result: BodyPartDataBase, raw: Dictionary) -> void:
	result.skeleton_model_path = _string(_subrecord(raw, "MODL"))
	result.ragdoll_form_id = _u32(_subrecord(raw, "RAGA"))
	result.parts.clear()
	var current: BodyPartDataPart = null
	for subrecord in raw.get("subrecords", []):
		var tag := String(subrecord.get("type", ""))
		var data: PackedByteArray = subrecord.get("data", PackedByteArray())
		if tag == "BPTN":
			if current != null:
				result.parts.append(current)
			current = BodyPartDataPart.new()
			current.part_name = _string(data)
		elif tag == "BPNN":
			# BPTD permits an unnamed collection, which begins at BPNN. A second
			# BPNN therefore begins the next collection if the current one is full.
			if current == null or not current.part_node.is_empty():
				if current != null:
					result.parts.append(current)
				current = BodyPartDataPart.new()
			current.part_node = _string(data)
		elif current != null and tag == "BPNT":
			current.vats_target = _string(data)
		elif current != null and tag == "BPNI":
			current.ik_start_node = _string(data)
		elif current != null and tag == "BPND":
			_populate_body_part_numeric_data(current, data, result)
		elif current != null and tag == "NAM1":
			current.limb_replacement_model = _string(data)
		elif current != null and tag == "NAM4":
			current.gore_target_bone = _string(data)
		elif current != null and tag == "NAM5":
			current.texture_file_hashes = data.duplicate()
	if current != null:
		result.parts.append(current)

func _populate_body_part_numeric_data(part: BodyPartDataPart, data: PackedByteArray, owner: BodyPartDataBase) -> void:
	part.raw_bpnd = data.duplicate()
	if data.size() != 84:
		owner.diagnostics.append("BPTD 0x%08X BPND has %d bytes; expected 84" % [owner.form_id, data.size()])
		return
	part.damage_multiplier = _f32(data)
	part.flags = _u8(data, 4)
	part.part_type = _u8(data, 5)
	part.health_percent = _u8(data, 6)
	part.actor_value = _i8(data, 7)
	part.hit_chance = _u8(data, 8)
	part.explosion_chance = _u8(data, 9)
	part.explosion_debris_count = _u16(data, 10)
	part.explosion_debris_form_id = _u32(data, 12)
	part.explosion_form_id = _u32(data, 16)
	part.tracking_max_angle = _f32(data, 20)
	part.explosion_debris_scale = _f32(data, 24)
	part.severable_debris_count = _i32(data, 28)
	part.severable_debris_form_id = _u32(data, 32)
	part.severable_explosion_form_id = _u32(data, 36)
	part.severable_debris_scale = _f32(data, 40)
	part.gore_translation = Vector3(_f32(data, 44), _f32(data, 48), _f32(data, 52))
	part.gore_rotation = Vector3(_f32(data, 56), _f32(data, 60), _f32(data, 64))
	part.severable_impact_dataset_form_id = _u32(data, 68)
	part.explosion_impact_dataset_form_id = _u32(data, 72)
	part.severable_decal_count = _u8(data, 76)
	part.explosion_decal_count = _u8(data, 77)
	part.limb_replacement_scale = _f32(data, 80)

func _join_creature_asset_path(directory: String, filename: String) -> String:
	var clean_filename := filename.replace("/", "\\")
	if directory.is_empty():
		return clean_filename
	return (directory + "\\" + clean_filename).replace("/", "\\")

func _string(data: PackedByteArray) -> String:
	var end := data.size()
	for i in data.size():
		if data[i] == 0: end = i; break
	return data.slice(0, end).get_string_from_ascii()

func _zero_terminated_strings(data: PackedByteArray) -> Array[String]:
	var result: Array[String] = []
	var start := 0
	for index in data.size():
		if data[index] != 0:
			continue
		if index > start:
			result.append(data.slice(start, index).get_string_from_ascii())
		start = index + 1
	if start < data.size():
		result.append(data.slice(start, data.size()).get_string_from_ascii())
	return result

func _u32(data: PackedByteArray, offset := 0) -> int:
	return int(data.decode_u32(offset)) if data.size() >= offset + 4 else 0
func _i16(data: PackedByteArray, offset := 0) -> int:
	return int(data.decode_s16(offset)) if data.size() >= offset + 2 else 0
func _u16(data: PackedByteArray, offset := 0) -> int:
	return int(data.decode_u16(offset)) if data.size() >= offset + 2 else 0
func _u8(data: PackedByteArray, offset := 0) -> int:
	return int(data[offset]) if data.size() > offset else 0
func _i8(data: PackedByteArray, offset := 0) -> int:
	var value := _u8(data, offset)
	return value - 256 if value >= 128 else value
func _i32(data: PackedByteArray, offset := 0) -> int:
	return int(data.decode_s32(offset)) if data.size() >= offset + 4 else 0
func _f32(data: PackedByteArray, offset := 0) -> float:
	return data.decode_float(offset) if data.size() >= offset + 4 else 0.0

func _sound_path(form_id: int) -> String:
	if form_id == 0 or reader == null or not reader.has_method("get_sound_path"):
		return ""
	return String(reader.get_sound_path(form_id))

func _parse_authored_id(id: String) -> int:
	var suffix := id.trim_prefix("authored:")
	return ("0x" + suffix).hex_to_int() if suffix.length() == 8 else 0

func _parse_prefixed_form_id(id: String, prefix: String) -> int:
	var suffix := id.trim_prefix(prefix)
	return ("0x" + suffix).hex_to_int() if suffix.length() == 8 else 0

func _parse_source_uri(uri: String) -> Dictionary:
	if not uri.begins_with("esm://"):
		return {}
	var parts := uri.trim_prefix("esm://").split("/")
	if parts.size() != 3 or parts[0] != "FalloutNV.esm" or parts[1].is_empty() or parts[2].length() != 8:
		return {}
	var form_id := ("0x" + parts[2]).hex_to_int()
	if form_id == 0:
		return {}
	return {"plugin": parts[0], "record_type": parts[1], "form_id": form_id}

func _has_property(object: Object, property_name: String) -> bool:
	for property in object.get_property_list():
		if String(property.get("name", "")) == property_name:
			return true
	return false

func _snake_case(value: String) -> String:
	var out := ""
	for i in value.length():
		var c := value[i]
		if i > 0 and c == c.to_upper() and c != c.to_lower(): out += "_"
		out += c.to_lower()
	return out
