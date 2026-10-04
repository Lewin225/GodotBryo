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
## The subfolders of ResourceRoot holding Base and Reference classes.
const BaseFolder := "Base/"
const ReferenceFolder := "Reference/"
const TYPE_TO_BASE := {
	"NPC_": "NpcBase", "RACE": "RaceBase", "HAIR": "HairBase", "EYES": "EyesBase",
	"CLAS": "ClassBase", "PACK": "PackageBase", "ARMO": "ArmorBase", "ARMA": "ArmorAddonBase",
	"FLST": "FormListBase", "WEAP": "WeaponBase", "ALCH": "AlchemyBase", "LVLI": "LeveledItemBase",
	"AMMO": "AmmoBase", "BOOK": "BookBase", "CCRD": "CaravanCardBase", "CMNY": "CaravanMoneyBase",
	"KEYM": "KeyBase", "MISC": "MiscBase", "DOOR": "DoorBase", "SCOL": "StaticCollectionBase",
	"LIGH": "LightBase", "CONT": "ContainerBase", "ACTI": "ActivatorBase", "FURN": "FurnitureBase",
	"TACT": "TalkingActivatorBase", "MSTT": "MovableStaticBase", "TERM": "TerminalBase",
	"STAT": "StaticBase", "CREA": "CreatureBase", "BPTD": "BodyPartDataBase", "QUST": "QuestBase",
	"MESG": "MessageBase", "DIAL": "DialogueTopicBase", "INFO": "DialogueInfoBase",
	"VTYP": "VoiceTypeBase", "GLOB": "GlobalBase", "LVLN": "LeveledNpcBase", "LVLC": "LeveledCreatureBase",
	"HDPT": "HeadPartBase", "IPDS": "ImpactDatasetBase", "SOUN": "SoundBase", "FACT": "FactionBase",
	"ENCH": "EnchantmentBase", "SPEL": "SpellBase", "CSTY": "CombatStyleBase", "SCPT": "ScriptBase",
	"NOTE": "NoteBase", "EXPL": "ExplosionBase", "DEBR": "DebrisBase", "ECZN": "EncounterZoneBase",
	"IDLE": "IdleBase"
}
const TYPE_TO_REFERENCE := {
	"NPC_": "NpcReference", "CREA": "CreatureReference", "WEAP": "WeaponReference", "ARMO": "ArmorReference",
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
var _quest_by_editor_id: Dictionary = {} # lowercased QUST EDID -> FormID
var _global_by_editor_id: Dictionary = {} # lowercased GLOB EDID -> FormID
var _base_by_editor_id: Dictionary = {} # lowercased EDID of any non-placement record -> FormID
var _topic_infos: Dictionary = {} # DIAL -> PackedInt64Array of its INFO FormIDs, in file order
var _info_topics: Dictionary = {} # INFO -> DIAL
var _game_setting_by_editor_id: Dictionary = {} # lowercased GMST EDID -> FormID
var _game_settings: Dictionary = {} # lowercased GMST EDID -> value, once read
## References whose cell has changed since they were built, by current CELL:
## CELL -> {EsmReference: true}. They are listed only under that CELL.
var _relocated_by_cell: Dictionary = {}
var _relocated: Dictionary = {} # EsmReference -> current CELL
var _player_reference: NpcReference = null

## FormID of the Player NPC_ record. The player's own placed reference
## (PlayerRef, 0x14) is not an ESM record; get_player_reference() stands in
## for it.
const PLAYER_BASE_FORM_ID := 0x00000007
const PLAYER_INSTANCE_ID := "player"
var _game_session = null
var _load_thread: Thread
var _load_result: Dictionary = {}
var state := "loading"
var _pending_rehydrates: Array[EsmBase] = []

func _ready() -> void:
	reference_cell_changed.connect(_on_reference_cell_changed)
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
	_quest_by_editor_id = _load_result.get("quest_by_editor_id", {})
	_global_by_editor_id = _load_result.get("global_by_editor_id", {})
	_base_by_editor_id = _load_result.get("base_by_editor_id", {})
	_game_setting_by_editor_id = _load_result.get("game_setting_by_editor_id", {})
	_topic_infos = _load_result.get("topic_infos", {})
	_info_topics = _load_result.get("info_topics", {})
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
	@warning_ignore("integer_division")
	ids.resize(pairs.size() / 2)
	@warning_ignore("integer_division")
	cells.resize(pairs.size() / 2)
	for i in ids.size():
		ids[i] = pairs[i * 2]
		cells[i] = pairs[i * 2 + 1]
	var by_editor_id := {}
	var quests := {}
	var globals := {}
	var bases := {}
	var game_settings := {}
	# Every INFO sits in its DIAL's child GRUP, which follows the DIAL, so an
	# INFO belongs to the last DIAL before it in file order.
	var topic_infos := {}
	var info_topics := {}
	var topic := 0
	for row: Dictionary in record_index:
		var record_type := String(row.get("record_type", ""))
		if record_type == "DIAL":
			topic = int(row["form_id"])
			topic_infos[topic] = PackedInt64Array()
		elif record_type == "INFO" and topic != 0:
			var infos: PackedInt64Array = topic_infos[topic]
			infos.append(int(row["form_id"]))
			topic_infos[topic] = infos
			info_topics[int(row["form_id"])] = topic
		var editor_id := String(row.get("editor_id", ""))
		if editor_id.is_empty():
			continue
		if record_type == "REFR" or record_type == "ACHR" or record_type == "ACRE":
			by_editor_id[editor_id.to_lower()] = int(row["form_id"])
			continue
		bases[editor_id.to_lower()] = int(row["form_id"])
		if record_type == "QUST":
			quests[editor_id.to_lower()] = int(row["form_id"])
		elif record_type == "GLOB":
			globals[editor_id.to_lower()] = int(row["form_id"])
		elif record_type == "GMST":
			game_settings[editor_id.to_lower()] = int(row["form_id"])
	return {"placed_reference_ids": ids, "placed_reference_cells": cells, "reference_by_editor_id": by_editor_id,
			"quest_by_editor_id": quests, "global_by_editor_id": globals, "base_by_editor_id": bases,
			"game_setting_by_editor_id": game_settings, "topic_infos": topic_infos, "info_topics": info_topics}

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
	var script := _resource_script(script_name)
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
	var script_name := String(TYPE_TO_BASE.get(String(raw.get("record_type", "")), "EsmBase"))
	return _resource_script(script_name)

func get_reference_type(refr_form_id: int) -> Script:
	var raw: Dictionary = reader.get_record_data(refr_form_id) if reader != null else {}
	if raw.is_empty():
		return null
	var base_id := _u32(_subrecord(raw, "NAME"))
	var base_raw: Dictionary = reader.get_record_data(base_id) if base_id != 0 else {}
	var script_name := String(TYPE_TO_REFERENCE.get(String(base_raw.get("record_type", "")), "EsmReference"))
	return _resource_script(script_name)

func get_reference(instance_id: String) -> EsmReference:
	if _game_session != null:
		return _game_session.get_reference(instance_id)
	if instance_id == PLAYER_INSTANCE_ID:
		return get_player_reference()
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

## The player's reference: one NpcReference on the Player NPC_ record, the
## same instance on every call. Unplaced (space 0) until something moves it.
func get_player_reference() -> NpcReference:
	if _player_reference == null and is_ready():
		_player_reference = create_reference_for_base(PLAYER_BASE_FORM_ID) as NpcReference
		if _player_reference != null:
			_player_reference.instance_id = PLAYER_INSTANCE_ID
	return _player_reference

## The placed reference with this editor ID, or null. Case-insensitive.
func find_reference_by_editor_id(editor_id: String) -> EsmReference:
	var form_id := int(_reference_by_editor_id.get(editor_id.to_lower(), 0))
	return get_reference("authored:%08X" % form_id) if form_id != 0 else null

## The QUST record with this editor ID, or null. Case-insensitive. Its
## script_form_id is the quest script whose variables scripts reach as
## `QuestEditorID.var`.
func find_quest_by_editor_id(editor_id: String) -> EsmBase:
	var form_id := int(_quest_by_editor_id.get(editor_id.to_lower(), 0))
	return get_base(form_id) if form_id != 0 else null

## The FormID of the non-placement record (a base, CELL, WRLD, QUST, ...) with
## this editor ID, or 0. Case-insensitive, from an in-memory index, unlike
## EsmReader's find_cell_by_editor_id / find_worldspace_by_editor_id, which
## scan every record.
func find_form_id_by_editor_id(editor_id: String) -> int:
	return int(_base_by_editor_id.get(editor_id.to_lower(), 0))

## The non-placement record (a base, QUST, GLOB, ...) with this editor ID, or
## null. Case-insensitive, from an in-memory index.
func find_base_by_editor_id(editor_id: String) -> EsmBase:
	var form_id := int(_base_by_editor_id.get(editor_id.to_lower(), 0))
	return get_base(form_id) if form_id != 0 else null

## The GLOB record with this editor ID as {"form_id", "editor_id", "type"
## ("s" short, "l" long, "f" float), "value" (its authored FLTV)}, or {} when
## there is none. Case-insensitive, from an in-memory index.
func find_global_by_editor_id(editor_id: String) -> Dictionary:
	var form_id := int(_global_by_editor_id.get(editor_id.to_lower(), 0))
	return reader.get_global_variable(form_id) if form_id != 0 and reader != null else {}

## A GMST's value by editor ID (case-insensitive): float for an `f` setting,
## int for `i`, bool for `b`, String for `s`; null when FalloutNV.esm has no
## such GMST (the engine's own default applies).
func get_game_setting(editor_id: String) -> Variant:
	var key := editor_id.to_lower()
	if _game_settings.has(key):
		return _game_settings[key]
	var form_id := int(_game_setting_by_editor_id.get(key, 0))
	var value: Variant = null
	if form_id != 0 and reader != null:
		var data := _subrecord(reader.get_record_data(form_id), "DATA")
		match key.left(1):
			"f": value = _f32(data)
			"i": value = _i32(data)
			"b": value = _u32(data) != 0
			"s": value = _string(data)
	_game_settings[key] = value
	return value

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
	var script := _resource_script(script_name)
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
	_populate_actor_values(result)
	_populate_terminal_lock(result)
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

## The references currently in a CELL: those filed in it that have not moved
## to another CELL, and those that have moved into it.
func get_references_in_cell(cell_form_id: int) -> Array[EsmReference]:
	var result: Array[EsmReference] = []
	if reader == null:
		return result
	for placement in reader.get_cell_references(cell_form_id) + reader.get_cell_actors(cell_form_id):
		var reference := _reference_from_placement(placement, "authored:%08X" % int(placement.get("refr_form_id", 0)), cell_form_id)
		if reference != null and not _relocated.has(reference):
			result.append(reference)
	for reference: EsmReference in _relocated_by_cell.get(cell_form_id, {}):
		result.append(reference)
	return result

## Whether a reference's cell has changed since it was built.
func is_relocated(reference: EsmReference) -> bool:
	return _relocated.has(reference)

func _on_reference_cell_changed(reference: EsmReference, old_cell_form_id: int, new_cell_form_id: int) -> void:
	if _relocated_by_cell.has(old_cell_form_id):
		(_relocated_by_cell[old_cell_form_id] as Dictionary).erase(reference)
	if not _relocated_by_cell.has(new_cell_form_id):
		_relocated_by_cell[new_cell_form_id] = {}
	_relocated_by_cell[new_cell_form_id][reference] = true
	_relocated[reference] = new_cell_form_id

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
		if reference != null and reference.has_teleport:
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
		if reference != null and reference.has_teleport:
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

## References filed in a worldspace's persistent CELL, excluding any whose
## cell has changed since they were built: those are listed only under their
## current CELL by get_references_in_cell().
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
		if reference != null and not _relocated.has(reference):
			result.append(reference)
	return result

func _reference_from_placement(placement: Dictionary, id: String, cell_id: int) -> EsmReference:
	if _authored_reference_cache.has(id):
		return _authored_reference_cache[id]
	var type_tag := String(placement.get("base_type", ""))
	var script_name := String(TYPE_TO_REFERENCE.get(type_tag, "EsmReference"))
	var script = _resource_script(script_name)
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
	result.linked_reference_form_id = int(placement.get("linked_reference_form_id", 0))
	result.initially_disabled = bool(placement.get("initially_disabled", false))
	result.disabled = result.initially_disabled
	result.enable_parent_form_id = int(placement.get("enable_parent_form_id", 0))
	result.enable_parent_flags = int(placement.get("enable_parent_flags", 0))
	result.primitive_type = int(placement.get("primitive_type", 0)) as EsmReference.PrimitiveType
	result.primitive_bounds = placement.get("primitive_bounds", Vector3.ZERO)
	result.primitive_color = placement.get("primitive_color", Color(0, 0, 0, 0))
	_populate_reference_inventory(result)
	_populate_actor_values(result)
	if result is ActorReference:
		var actor: ActorReference = result
		actor.spawn_cell_form_id = cell_id
		actor.simulation_mode = ActorReference.SimulationMode.LOW_LEVEL
		_populate_actor_reference(actor, reader.get_record_data(int(placement.get("refr_form_id", 0))) if reader != null else {})
	if result is DoorReference:
		var door_ref: DoorReference = result
		var ref_raw: Dictionary = reader.get_record_data(int(placement.get("refr_form_id", 0))) if reader != null else {}
		var destination_form_id := int(placement.get("dest_refr_form_id", 0))
		if bool(placement.get("has_xtel", false)) and destination_form_id != 0:
			door_ref.has_teleport = true
			door_ref.teleport_destination_form_id = destination_form_id
			door_ref.teleport_position = placement.get("dest_position", Vector3.ZERO)
			door_ref.teleport_rotation = placement.get("dest_rotation", Vector3.ZERO)
			var xtel := _subrecord(ref_raw, "XTEL")
			door_ref.teleport_no_alarm = xtel.size() >= 32 and (_u32(xtel, 28) & 0x01) != 0
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
	if result is StaticReference or result is MovableStaticReference \
			or result is ActivatorReference or result is DoorReference or result is LightReference:
		result.emittance_form_id = int(placement.get("emittance_form_id", 0))
	_populate_terminal_lock(result)
	_authored_reference_cache[id] = result
	return result

## A terminal's lock state starts from its base's DNAM.
func _populate_terminal_lock(reference: EsmReference) -> void:
	var terminal := reference as TerminalReference
	if terminal == null or not terminal.base is TerminalBase:
		return
	var base := terminal.base as TerminalBase
	terminal.is_locked = not base.is_unlocked
	terminal.lock_level = base.hacking_difficulty

## Gives an actor or creature reference its ActorValues.
func _populate_actor_values(reference: EsmReference) -> void:
	if reference is ActorReference:
		reference.get_actor_values()

## Adds `count` of `item_base` to `holder`'s inventory as typed items, as a
## script's AddItem does. A leveled list resolves `count` times at the holder's
## level. Returns the number of items added; 0 when `holder` has no inventory.
func add_inventory_items(holder: EsmReference, item_base: EsmBase, count: int) -> int:
	var inventory: Inventory = holder.get("contents") if holder != null and "contents" in holder else null
	if inventory == null or item_base == null or count <= 0:
		return 0
	var added := 0
	if item_base is LeveledItemBase:
		var resolver := LeveledItemResolver.new(self)
		for i in count:
			for resolved in resolver.resolve(item_base as LeveledItemBase, _holder_level(holder), {}):
				if inventory.add_inventory_item(resolved):
					added += resolved.count
		return added
	var item_reference := _create_inventory_item_reference(item_base, item_base.form_id, inventory.items.size())
	if item_reference == null:
		return 0
	var item := InventoryItem.new()
	item.item_reference = item_reference
	item.count = count
	return count if inventory.add_inventory_item(item) else 0

## The level leveled lists resolve at for `holder`: an actor's level, else 1.
static func _holder_level(holder: EsmReference) -> int:
	var values: ActorValues = holder.get_actor_values() if holder != null else null
	return values.get_level() if values != null else 1

## An owner's Items (ActorBase.items, following the Inventory template flag;
## a container's CNTO) are the authored seed for its inventory. Each COED's
## owner and condition carry to the item. The live inventory is kept on the
## owner reference as typed item references and is not rebuilt from the base
## after the reference has been created.
func _populate_reference_inventory(reference: EsmReference) -> void:
	if not (reference is ActorReference or reference is ContainerReference):
		return
	var inventory := Inventory.new()
	reference.set("contents", inventory)
	var owner_base := reference.base
	if owner_base == null:
		return
	var items: Array[InitialItemCollection] = []
	if owner_base is ActorBase:
		var source := ActorBase.template_source(owner_base, ActorBase.TEMPLATE_USE_INVENTORY)
		items = source.items
	else:
		items = _initial_items({"subrecords": owner_base.raw_subrecords})
	var item_index := 0
	var resolver := LeveledItemResolver.new(self)
	var level := _holder_level(reference)
	for entry in items:
		var count := entry.count
		if entry.item is LeveledItemBase:
			var resolved := resolver.resolve(entry.item as LeveledItemBase, level, {"seed": owner_base.form_id ^ item_index})
			for resolved_item in resolved:
				resolved_item.instance_id = "inventory:%08X:%d" % [resolved_item.item_reference.base_form_id, item_index]
				if count > 1:
					resolved_item.count *= count
				reference.contents.add_inventory_item(resolved_item)
				item_index += 1
			continue
		var item_reference := _create_inventory_item_reference(entry.item, entry.item_form_id, item_index)
		if item_reference == null or count <= 0:
			item_index += 1
			continue
		var item := InventoryItem.new()
		item.item_reference = item_reference
		item.count = count
		item.instance_id = "inventory:%08X:%d" % [entry.item_form_id, item_index]
		item.owner_form_id = entry.owner_form_id
		item.health_percent = entry.condition
		inventory.add_item(item)
		item_index += 1
	if reference is NpcReference:
		inventory.equip_default_armor()

func _create_inventory_item_reference(item_base: EsmBase, form_id: int, index: int) -> EsmReference:
	if item_base == null:
		return null
	var script_name := String(TYPE_TO_REFERENCE.get(item_base.record_type, "EsmReference"))
	var script := _resource_script(script_name)
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
	result.script_form_id = _u32(_subrecord(raw, "SCRI"))
	result.script_record = get_base(result.script_form_id) as ScriptBase if result.script_form_id != 0 else null
	result.record_flags = int(raw.get("record_flags", 0))
	if result is LeveledItemBase:
		_populate_leveled_item(result as LeveledItemBase, raw)
	elif result is QuestBase:
		_populate_quest(result as QuestBase, raw)
	elif result is PackageBase:
		_populate_package(result as PackageBase, raw)
	elif result is MessageBase:
		_populate_message(result as MessageBase, raw)
	elif result is DialogueTopicBase:
		_populate_dialogue_topic(result as DialogueTopicBase, raw)
	elif result is DialogueInfoBase:
		_populate_dialogue_info(result as DialogueInfoBase, raw)
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
		weapon.biped_model_list = get_base(weapon.biped_model_list_form_id) as FormListBase
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
		_populate_npc(result as NpcBase, raw)
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
		armor.biped_model_list = get_base(armor.biped_model_list_form_id) as FormListBase
	elif result is ArmorAddonBase:
		var addon: ArmorAddonBase = result
		addon.model_path = _string(_subrecord(raw, "MODL"))
		addon.male_biped_model = addon.model_path
		addon.female_biped_model = _string(_subrecord(raw, "MOD3"))
		addon.biped_flags = _u32(_subrecord(raw, "BMDT"))
	elif result is FormListBase:
		var form_list: FormListBase = result
		form_list.entries.clear()
		for entry_data in _all_subrecords(raw, "LNAM"):
			var entry := get_base(_u32(entry_data))
			if entry != null: form_list.entries.append(entry)
	elif result is VoiceTypeBase:
		(result as VoiceTypeBase).flags = _u8(_subrecord(raw, "DNAM"))
	elif result is GlobalBase:
		var global_base: GlobalBase = result
		var fnam := _subrecord(raw, "FNAM")
		global_base.global_type = char(fnam[0]) if not fnam.is_empty() else GlobalBase.TYPE_FLOAT
		global_base.value = _f32(_subrecord(raw, "FLTV"))
	elif result is DoorBase:
		var door: DoorBase = result
		door.model_path = _string(_subrecord(raw, "MODL"))
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
		furniture.marker_flags = _subrecord(raw, "MNAM")
	elif result is BookBase or result is CaravanCardBase or result is CaravanMoneyBase:
		result.set("model_path", _string(_subrecord(raw, "MODL")))
	elif result is TalkingActivatorBase:
		var talking_activator: TalkingActivatorBase = result
		talking_activator.model_path = _string(_subrecord(raw, "MODL"))
		talking_activator.voice_type_form_id = _u32(_subrecord(raw, "VNAM"))
		talking_activator.sound_form_id = _u32(_subrecord(raw, "SNAM"))
		talking_activator.sound_path = _sound_path(talking_activator.sound_form_id)
	elif result is TerminalBase:
		var terminal: TerminalBase = result
		terminal.model_path = _string(_subrecord(raw, "MODL"))
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
				var item := TerminalMenuItemCollection.new()
				item.text = String(item_data.get("text", ""))
				item.result_text = String(item_data.get("result_text", ""))
				item.item_flags = int(item_data.get("flags", 0))
				item.display_note_form_id = int(item_data.get("note_form_id", 0))
				item.submenu_terminal_form_id = int(item_data.get("submenu_form_id", 0))
				item.script_source = String(item_data.get("script_source", ""))
				terminal.menu_items.append(item)
		# Each menu item starts at its ITXT; its CTDAs follow its other fields.
		var item_index := -1
		for sub: Dictionary in raw.get("subrecords", []):
			var tag := String(sub.get("type", ""))
			if tag == "ITXT":
				item_index += 1
			elif tag == "CTDA" and item_index >= 0 and item_index < terminal.menu_items.size():
				_append_condition(terminal.menu_items[item_index].conditions, terminal, sub.get("data", PackedByteArray()))
	else:
		if _has_property(result, "model_path"):
			result.set("model_path", _string(_subrecord(raw, "MODL")))
	result._rehydrating = false

func _populate_dialogue_topic(topic: DialogueTopicBase, raw: Dictionary) -> void:
	topic.quest_form_ids.clear()
	for data in _all_subrecords(raw, "QSTI"):
		topic.quest_form_ids.append(_u32(data))
	var data := _subrecord(raw, "DATA")
	topic.topic_type = _u8(data) as DialogueTopicBase.Type
	topic.flags = _u8(data, 1)
	topic.priority = _f32(_subrecord(raw, "PNAM")) if _subrecord_present(raw, "PNAM") else 50.0
	topic.infos.clear()
	for form_id in _topic_infos.get(topic.form_id, PackedInt64Array()):
		var info := get_base(form_id) as DialogueInfoBase
		if info != null:
			topic.infos.append(info)

func _populate_dialogue_info(info: DialogueInfoBase, raw: Dictionary) -> void:
	info.topic_form_id = int(_info_topics.get(info.form_id, 0))
	info.quest_form_id = _u32(_subrecord(raw, "QSTI"))
	info.quest = get_base(info.quest_form_id) as QuestBase
	var data := _subrecord(raw, "DATA")
	info.info_type = _u8(data) as DialogueTopicBase.Type
	info.next_speaker = _u8(data, 1)
	info.flags = _u8(data, 2)
	info.flags_2 = _u8(data, 3)
	info.prompt = _string(_subrecord(raw, "RNAM"))
	info.speaker_form_id = _u32(_subrecord(raw, "ANAM"))
	info.actor_value_or_perk_form_id = _u32(_subrecord(raw, "KNAM"))
	info.speech_challenge = _u32(_subrecord(raw, "DNAM"))
	info.responses.clear()
	info.conditions.clear()
	info.link_to_form_ids.clear()
	info.link_from_form_ids.clear()
	info.follow_up_form_ids.clear()
	info.add_topic_form_ids.clear()
	info.begin_script_source = ""
	info.end_script_source = ""
	# A response starts at its TRDT; its NAM1-LNAM follow. The SCTX before NEXT
	# is the begin script, the one after it the end script.
	var response: DialogueResponseCollection = null
	var after_next := false
	for sub: Dictionary in raw.get("subrecords", []):
		var tag := String(sub.get("type", ""))
		var bytes: PackedByteArray = sub.get("data", PackedByteArray())
		match tag:
			"TRDT":
				response = DialogueResponseCollection.new()
				response.emotion = _u32(bytes) as DialogueResponseCollection.Emotion
				response.emotion_value = _i32(bytes, 4)
				response.response_number = _u8(bytes, 12)
				response.sound_form_id = _u32(bytes, 16)
				response.uses_emotion_animation = _u8(bytes, 20) != 0
				info.responses.append(response)
			"NAM1":
				if response != null: response.text = _string(bytes)
			"NAM2":
				if response != null: response.script_notes = _string(bytes)
			"NAM3":
				if response != null: response.edits = _string(bytes)
			"SNAM":
				if response != null: response.speaker_idle_form_id = _u32(bytes)
			"LNAM":
				if response != null: response.listener_idle_form_id = _u32(bytes)
			"CTDA":
				_append_condition(info.conditions, info, bytes)
			"TCLT":
				info.link_to_form_ids.append(_u32(bytes))
			"TCLF":
				info.link_from_form_ids.append(_u32(bytes))
			"TCFU":
				info.follow_up_form_ids.append(_u32(bytes))
			"NAME":
				info.add_topic_form_ids.append(_u32(bytes))
			"NEXT":
				after_next = true
			"SCTX":
				if after_next:
					info.end_script_source = _string(bytes)
				else:
					info.begin_script_source = _string(bytes)

func _populate_message(message: MessageBase, raw: Dictionary) -> void:
	message.description = _string(_subrecord(raw, "DESC"))
	message.icon_form_id = _u32(_subrecord(raw, "INAM"))
	message.flags = _u32(_subrecord(raw, "DNAM"))
	message.display_time = _u32(_subrecord(raw, "TNAM"))
	message.buttons.clear()
	# Each button starts at its ITXT; its CTDAs follow it.
	for sub: Dictionary in raw.get("subrecords", []):
		var tag := String(sub.get("type", ""))
		var data: PackedByteArray = sub.get("data", PackedByteArray())
		if tag == "ITXT":
			var button := MessageButtonCollection.new()
			button.text = _string(data)
			message.buttons.append(button)
		elif tag == "CTDA" and not message.buttons.is_empty():
			_append_condition(message.buttons.back().conditions, message, data)

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
			var body := RacePartCollection.new()
			body.index = int(item.get("index", 0))
			body.part_type = _race_body_part_type(body.index)
			body.model_path = String(item.get("model", ""))
			body.icon_path = String(item.get("icon", ""))
			if female: race.female_body_parts.append(body)
			else: race.male_body_parts.append(body)
		var head_parts: Array = reader.get_race_head_parts(race.form_id, female)
		for item in head_parts:
			var head := RacePartCollection.new()
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

## QUST DATA, stages and objectives. Subrecords are read in order. Before the
## first QOBJ, INDX opens a stage and QSDT a log entry of it; CTDA, CNAM and
## SCTX belong to the current entry. From the first QOBJ on, QOBJ opens an
## objective, NNAM is its text, QSTA opens a target of it and CTDA belongs to
## the current target.
func _populate_quest(result: QuestBase, raw: Dictionary) -> void:
	var data := _subrecord(raw, "DATA")
	result.flags = _u8(data)
	result.starts_enabled = (result.flags & 0x01) != 0
	result.allows_repeated_topics = (result.flags & 0x04) != 0
	result.allows_repeated_stages = (result.flags & 0x08) != 0
	result.uses_default_script_delay = (result.flags & 0x10) != 0
	result.priority = _u8(data, 1) if data.size() >= 2 else 0
	result.script_delay = _f32(data, 4) if data.size() >= 8 else 0.0
	result.conditions.clear()
	result.stages.clear()
	result.objectives.clear()
	var stage: QuestStageCollection = null
	var entry: QuestLogEntryCollection = null
	var objective: QuestObjectiveCollection = null
	var target: QuestObjectiveTargetCollection = null
	for sub: Dictionary in raw.get("subrecords", []):
		var tag := String(sub.get("type", ""))
		var bytes: PackedByteArray = sub.get("data", PackedByteArray())
		if objective != null or tag == "QOBJ":
			match tag:
				"QOBJ":
					objective = QuestObjectiveCollection.new()
					objective.index = _i32(bytes)
					result.objectives.append(objective)
					target = null
				"NNAM":
					objective.text = _string(bytes)
				"QSTA":
					target = QuestObjectiveTargetCollection.new()
					target.reference_form_id = _u32(bytes)
					target.flags = _u8(bytes, 4)
					objective.targets.append(target)
				"CTDA":
					if target != null:
						_append_condition(target.conditions, result, bytes)
			continue
		match tag:
			"INDX":
				stage = QuestStageCollection.new()
				stage.index = _i16(bytes)
				result.stages.append(stage)
				entry = null
			"QSDT":
				if stage != null:
					entry = QuestLogEntryCollection.new()
					entry.flags = _u8(bytes)
					stage.log_entries.append(entry)
			"CTDA":
				if entry != null:
					_append_condition(entry.conditions, result, bytes)
				elif stage == null:
					_append_condition(result.conditions, result, bytes)
			"CNAM":
				if entry != null:
					entry.log_text = _string(bytes)
			"SCTX":
				if entry != null:
					entry.script_source = bytes.get_string_from_ascii()

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
		var entry := LeveledItemEntryCollection.new()
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
	_reset_package(result)
	var current_event: PackageEventCollection = null
	for subrecord in raw.get("subrecords", []):
		var tag := String(subrecord.get("type", ""))
		var data: PackedByteArray = subrecord.get("data", PackedByteArray())
		match tag:
			"PKDT":
				_read_package_general(result, data)
			"PLDT":
				_read_package_location(result, 1, data)
			"PLD2":
				_read_package_location(result, 2, data)
			"PSDT":
				_read_package_schedule(result, data)
			"PTDT":
				_read_package_target(result, 1, data)
			"PTD2":
				_read_package_target(result, 2, data)
			"CTDA":
				_append_condition(result.conditions, result, data)
			"IDLA":
				for offset in range(0, data.size() - 3, 4):
					var idle := get_base(_u32(data, offset)) as IdleBase
					if idle != null:
						result.idle_animations.append(idle)
			"IDLC":
				result.idle_collection_chance_raw = data.duplicate()
			"IDLF":
				result.idle_collection_flags_raw = data.duplicate()
			"IDLT":
				result.idle_collection_timer_raw = data.duplicate()
			"CNAM":
				result.combat_style_form_id = _u32(data)
				result.combat_style = get_base(result.combat_style_form_id) as CombatStyleBase
			"PKED":
				result.has_eat_marker = true
			"PKE2":
				result.escort_distance = _u32(data)
			"PKFD":
				result.follow_start_location_trigger_radius = _f32(data)
			"PKPT":
				result.patrol_repeatable = _u8(data) != 0
			"PKW3":
				_read_package_use_weapon(result, data)
			"PUID":
				result.has_use_item_marker = true
			"PKAM":
				result.has_ambush_marker = true
			"PKDD":
				_read_package_dialogue(result, data)
			"POBA":
				current_event = PackageEventCollection.new()
				result.on_begin = current_event
			"POEA":
				current_event = PackageEventCollection.new()
				result.on_end = current_event
			"POCA":
				current_event = PackageEventCollection.new()
				result.on_change = current_event
			_:
				if current_event != null:
					_populate_package_event_subrecord(current_event, tag, data)

## Clears a package's fields before it is (re)filled from its record.
func _reset_package(result: PackageBase) -> void:
	result.general_flags = 0
	result.package_type = PackageBase.PackageType.FIND
	result.fallout_behavior_flags = 0
	result.type_specific_flags = 0
	result.has_location_1 = false
	result.has_location_2 = false
	result.has_target_1 = false
	result.has_target_2 = false
	result.has_use_weapon_data = false
	result.has_dialogue_data = false
	result.conditions.clear()
	result.idle_animations.clear()
	result.idle_collection_chance_raw = PackedByteArray()
	result.idle_collection_flags_raw = PackedByteArray()
	result.idle_collection_timer_raw = PackedByteArray()
	result.combat_style_form_id = 0
	result.combat_style = null
	result.has_eat_marker = false
	result.escort_distance = 0
	result.follow_start_location_trigger_radius = 0.0
	result.patrol_repeatable = true
	result.has_use_item_marker = false
	result.has_ambush_marker = false
	result.on_begin = null
	result.on_end = null
	result.on_change = null

## PKDT: the 12-byte FNV form, or the old 8-byte form (13 records) without the
## Fallout Behavior and Type Specific flag words.
func _read_package_general(result: PackageBase, data: PackedByteArray) -> void:
	if data.size() != 8 and data.size() != 12:
		result.diagnostics.append("PACK 0x%08X has PKDT with %d bytes; expected 8 or 12" % [result.form_id, data.size()])
		return
	result.general_flags = _u32(data)
	result.package_type = _u8(data, 4) as PackageBase.PackageType
	if data.size() == 12:
		result.fallout_behavior_flags = _u16(data, 6)
		result.type_specific_flags = _u16(data, 8)

## PLDT (`index` 1) or PLD2 (2): type, the record or object type it names, and
## radius. A placed reference keeps only its FormID (PackageBase resolves it on
## demand); an Object ID resolves to its base.
func _read_package_location(result: PackageBase, index: int, data: PackedByteArray) -> void:
	if data.size() != 12:
		result.diagnostics.append("PACK 0x%08X has %s with %d bytes; expected 12" % [result.form_id, "PLDT" if index == 1 else "PLD2", data.size()])
		return
	var type := _i32(data) as PackageBase.LocationType
	var value := _u32(data, 4)
	var names_record := type == PackageBase.LocationType.NEAR_REFERENCE or type == PackageBase.LocationType.IN_CELL or type == PackageBase.LocationType.OBJECT_ID
	var form_id := value if names_record else 0
	var object: EsmBase = get_base(value) if type == PackageBase.LocationType.OBJECT_ID else null
	var object_type := (value as PackageBase.ObjectType) if type == PackageBase.LocationType.OBJECT_TYPE else PackageBase.ObjectType.NONE
	var radius := _i32(data, 8)
	if index == 1:
		result.has_location_1 = true
		result.location_1_type = type
		result.location_1_form_id = form_id
		result.location_1_object = object
		result.location_1_object_type = object_type
		result.location_1_radius = radius
	else:
		result.has_location_2 = true
		result.location_2_type = type
		result.location_2_form_id = form_id
		result.location_2_object = object
		result.location_2_object_type = object_type
		result.location_2_radius = radius

func _read_package_schedule(result: PackageBase, data: PackedByteArray) -> void:
	if data.size() != 8:
		result.diagnostics.append("PACK 0x%08X has PSDT with %d bytes; expected 8" % [result.form_id, data.size()])
		return
	result.schedule_month = _i8(data)
	result.schedule_day_of_week = _i8(data, 1)
	result.schedule_date = _i8(data, 2)
	result.schedule_time = _i8(data, 3)
	result.schedule_duration_hours = _u32(data, 4)

## PTDT (`index` 1) or PTD2 (2): type, the record or object type it names,
## count / distance and the unknown float. As for locations, a placed reference
## keeps only its FormID.
func _read_package_target(result: PackageBase, index: int, data: PackedByteArray) -> void:
	if data.size() != 16:
		result.diagnostics.append("PACK 0x%08X has %s with %d bytes; expected 16" % [result.form_id, "PTDT" if index == 1 else "PTD2", data.size()])
		return
	var type := _i32(data) as PackageBase.TargetType
	var value := _u32(data, 4)
	var names_record := type == PackageBase.TargetType.SPECIFIC_REFERENCE or type == PackageBase.TargetType.OBJECT_ID
	var object: EsmBase = get_base(value) if type == PackageBase.TargetType.OBJECT_ID else null
	var object_type := (value as PackageBase.ObjectType) if type == PackageBase.TargetType.OBJECT_TYPE else PackageBase.ObjectType.NONE
	var form_id := value if names_record else 0
	var count_or_distance := _i32(data, 8)
	var unknown := _f32(data, 12)
	if index == 1:
		result.has_target_1 = true
		result.target_1_type = type
		result.target_1_form_id = form_id
		result.target_1_object = object
		result.target_1_object_type = object_type
		result.target_1_count_or_distance = count_or_distance
		result.target_1_unknown = unknown
	else:
		result.has_target_2 = true
		result.target_2_type = type
		result.target_2_form_id = form_id
		result.target_2_object = object
		result.target_2_object_type = object_type
		result.target_2_count_or_distance = count_or_distance
		result.target_2_unknown = unknown

## One CTDA as a ConditionSubrecord. 28-byte CTDAs carry Run On and Reference, the
## 24-byte form Run On only, the 20-byte form neither. Null, with a diagnostic
## on `record`, for any other size.
func _condition(record: EsmBase, data: PackedByteArray) -> ConditionSubrecord:
	if data.size() != 20 and data.size() != 24 and data.size() != 28:
		record.diagnostics.append("%s 0x%08X has CTDA with %d bytes; expected 20, 24 or 28" % [record.record_type, record.form_id, data.size()])
		return null
	var condition := ConditionSubrecord.new()
	var type := _u8(data)
	condition.comparison = (type >> 5) as ConditionSubrecord.Comparison
	condition.flags = type & 0x1F
	condition.comparison_value = _f32(data, 4)
	if condition.uses_global():
		condition.comparison_global_form_id = _u32(data, 4)
	condition.function_index = _u16(data, 8)
	condition.parameter_1 = _u32(data, 12)
	condition.parameter_2 = _u32(data, 16)
	if data.size() >= 24:
		condition.has_run_on = true
		condition.run_on = _u32(data, 20)
	if data.size() >= 28:
		condition.reference_form_id = _u32(data, 24)
	return condition

## Appends the ConditionSubrecord parsed from `data` to `conditions`, when it parses.
func _append_condition(conditions: Array[ConditionSubrecord], record: EsmBase, data: PackedByteArray) -> void:
	var condition := _condition(record, data)
	if condition != null:
		conditions.append(condition)

func _read_package_use_weapon(result: PackageBase, data: PackedByteArray) -> void:
	if data.size() != 24:
		result.diagnostics.append("PACK 0x%08X has PKW3 with %d bytes; expected 24" % [result.form_id, data.size()])
		return
	result.has_use_weapon_data = true
	result.use_weapon_flags = _u32(data)
	result.use_weapon_fire_rate = _u8(data, 4)
	result.use_weapon_fire_count = _u8(data, 5)
	result.use_weapon_burst_count = _u16(data, 6)
	result.use_weapon_shots_per_volley_min = _u16(data, 8)
	result.use_weapon_shots_per_volley_max = _u16(data, 10)
	result.use_weapon_pause_between_volleys_min = _f32(data, 12)
	result.use_weapon_pause_between_volleys_max = _f32(data, 16)

func _read_package_dialogue(result: PackageBase, data: PackedByteArray) -> void:
	if data.size() != 24:
		result.diagnostics.append("PACK 0x%08X has PKDD with %d bytes; expected 24" % [result.form_id, data.size()])
		return
	result.has_dialogue_data = true
	result.dialogue_field_of_view = _f32(data)
	result.dialogue_topic_form_id = _u32(data, 4)
	result.dialogue_topic = get_base(result.dialogue_topic_form_id) as DialogueTopicBase
	result.dialogue_flags = _u32(data, 8)
	result.dialogue_type = _u32(data, 16)
	result.dialogue_unknown = _u32(data, 20)

func _populate_package_event_subrecord(event: PackageEventCollection, tag: String, data: PackedByteArray) -> void:
	match tag:
		"INAM":
			event.idle_form_id = _u32(data)
			event.idle = get_base(event.idle_form_id) as IdleBase
		"TNAM":
			event.topic_form_id = _u32(data)
			event.topic = get_base(event.topic_form_id) as DialogueTopicBase
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
			var local := ScriptLocalCollection.new()
			local.index = _u32(data)
			local.variable_type = _u8(data, 16)
			local.raw_data = data.duplicate()
			event.local_variables.append(local)
		"SCVR":
			var local_name := _string(data)
			event.local_variable_names.append(local_name)
			if not event.local_variables.is_empty():
				event.local_variables.back().name = local_name
		"SCRO": event.script_references.append(_u32(data))
		"SCRV": event.script_local_reference_indices.append(_u32(data))

## An ACHR or ACRE's own subrecords beyond the placement: XLCM, XEZN, XMRC,
## ragdoll data, XATO, XAPD, XIBS, and on ACRE XOWN.
func _populate_actor_reference(actor: ActorReference, raw: Dictionary) -> void:
	actor.level_modifier = _i32(_subrecord(raw, "XLCM"))
	actor.encounter_zone_form_id = _u32(_subrecord(raw, "XEZN"))
	actor.encounter_zone = get_base(actor.encounter_zone_form_id) as EncounterZoneBase
	actor.merchant_container_form_id = _u32(_subrecord(raw, "XMRC"))
	actor.ragdoll_data = _subrecord(raw, "XRGD")
	actor.ragdoll_biped_data = _subrecord(raw, "XRGB")
	actor.activation_prompt = _string(_subrecord(raw, "XATO"))
	actor.parent_activate_only = _u8(_subrecord(raw, "XAPD")) != 0
	actor.ignored_by_sandbox = _subrecord_present(raw, "XIBS")
	if actor is CreatureReference:
		var creature: CreatureReference = actor
		creature.owner_form_id = _u32(_subrecord(raw, "XOWN"))
		creature.owner = get_base(creature.owner_form_id)

## An NPC_ or CREA's SNAM faction entries: FACT FormID and signed rank.
func _actor_factions(raw: Dictionary) -> Array[FactionSubrecord]:
	var factions: Array[FactionSubrecord] = []
	for data in _all_subrecords(raw, "SNAM"):
		var entry := FactionSubrecord.new()
		entry.faction_form_id = _u32(data)
		entry.rank = _i8(data, 4)
		factions.append(entry)
	return factions

## The fields NPC_ and CREA share (ActorBase).
func _populate_actor(actor: ActorBase, raw: Dictionary) -> void:
	actor.model_path = _string(_subrecord(raw, "MODL"))
	var obnd := _subrecord(raw, "OBND")
	if obnd.size() >= 12:
		actor.bounds_min = Vector3i(obnd.decode_s16(0), obnd.decode_s16(2), obnd.decode_s16(4))
		actor.bounds_max = Vector3i(obnd.decode_s16(6), obnd.decode_s16(8), obnd.decode_s16(10))
	var model_directory := actor.model_path.replace("\\", "/").get_base_dir()
	actor.animations = PackedStringArray()
	actor.animation_paths = PackedStringArray()
	for data in _all_subrecords(raw, "KFFZ"):
		for filename in _zero_terminated_strings(data):
			actor.animations.append(filename)
			actor.animation_paths.append(_join_creature_asset_path(model_directory, filename))
	var acbs := _subrecord(raw, "ACBS")
	actor.acbs_flags = _u32(acbs)
	actor.fatigue = _u16(acbs, 4)
	actor.barter_gold = _u16(acbs, 6)
	actor.level = _u16(acbs, 8)
	actor.calc_min = _u16(acbs, 10)
	actor.calc_max = _u16(acbs, 12)
	actor.speed_multiplier = _u16(acbs, 14)
	actor.karma = _f32(acbs, 16)
	actor.disposition_base = _i16(acbs, 20)
	actor.template_flags = _u16(acbs, 22)
	actor.template_form_id = _u32(_subrecord(raw, "TPLT"))
	actor.template = get_base(actor.template_form_id)
	actor.factions = _actor_factions(raw)
	actor.death_item_form_id = _u32(_subrecord(raw, "INAM"))
	actor.death_item = get_base(actor.death_item_form_id) as LeveledItemBase
	actor.voice_type_form_id = _u32(_subrecord(raw, "VTCK"))
	actor.voice_type = get_base(actor.voice_type_form_id) as VoiceTypeBase
	actor.combat_style_form_id = _u32(_subrecord(raw, "ZNAM"))
	actor.combat_style = get_base(actor.combat_style_form_id) as CombatStyleBase
	actor.impact_material_type = _u32(_subrecord(raw, "NAM4"))
	actor.actor_effects.clear()
	for data in _all_subrecords(raw, "SPLO"):
		var spell := get_base(_u32(data)) as SpellBase
		if spell != null: actor.actor_effects.append(spell)
	actor.unarmed_attack_effect_form_id = _u32(_subrecord(raw, "EITM"))
	actor.unarmed_attack_effect = get_base(actor.unarmed_attack_effect_form_id)
	actor.unarmed_attack_animation = _u16(_subrecord(raw, "EAMT"))
	var aidt := _subrecord(raw, "AIDT")
	actor.aggression = _u8(aidt, 0)
	actor.confidence = _u8(aidt, 1)
	actor.energy = _u8(aidt, 2)
	actor.responsibility = _u8(aidt, 3)
	actor.mood = _u8(aidt, 4)
	actor.services = _u32(aidt, 8)
	actor.teaches = _i8(aidt, 12)
	actor.maximum_training_level = _u8(aidt, 13)
	actor.assistance = _i8(aidt, 14)
	actor.aggro_radius_behavior = _u8(aidt, 15) != 0
	actor.aggro_radius = _i32(aidt, 16)
	actor.packages.clear()
	for data in _all_subrecords(raw, "PKID"):
		var package_base := get_base(_u32(data)) as PackageBase
		if package_base != null: actor.packages.append(package_base)
	actor.items = _initial_items(raw)
	actor.destructible = _destruction(raw)

func _populate_npc(npc: NpcBase, raw: Dictionary) -> void:
	_populate_actor(npc, raw)
	npc.is_child = false
	var data := _subrecord(raw, "DATA")
	npc.base_health = _i32(data)
	npc.strength = _u8(data, 4)
	npc.perception = _u8(data, 5)
	npc.endurance = _u8(data, 6)
	npc.charisma = _u8(data, 7)
	npc.intelligence = _u8(data, 8)
	npc.agility = _u8(data, 9)
	npc.luck = _u8(data, 10)
	var dnam := _subrecord(raw, "DNAM")
	npc.skill_barter = _u8(dnam, 0)
	npc.skill_big_guns = _u8(dnam, 1)
	npc.skill_energy_weapons = _u8(dnam, 2)
	npc.skill_explosives = _u8(dnam, 3)
	npc.skill_lockpick = _u8(dnam, 4)
	npc.skill_medicine = _u8(dnam, 5)
	npc.skill_melee_weapons = _u8(dnam, 6)
	npc.skill_repair = _u8(dnam, 7)
	npc.skill_science = _u8(dnam, 8)
	npc.skill_guns = _u8(dnam, 9)
	npc.skill_sneak = _u8(dnam, 10)
	npc.skill_speech = _u8(dnam, 11)
	npc.skill_survival = _u8(dnam, 12)
	npc.skill_unarmed = _u8(dnam, 13)
	npc.skill_offset_barter = _u8(dnam, 14)
	npc.skill_offset_big_guns = _u8(dnam, 15)
	npc.skill_offset_energy_weapons = _u8(dnam, 16)
	npc.skill_offset_explosives = _u8(dnam, 17)
	npc.skill_offset_lockpick = _u8(dnam, 18)
	npc.skill_offset_medicine = _u8(dnam, 19)
	npc.skill_offset_melee_weapons = _u8(dnam, 20)
	npc.skill_offset_repair = _u8(dnam, 21)
	npc.skill_offset_science = _u8(dnam, 22)
	npc.skill_offset_guns = _u8(dnam, 23)
	npc.skill_offset_sneak = _u8(dnam, 24)
	npc.skill_offset_speech = _u8(dnam, 25)
	npc.skill_offset_survival = _u8(dnam, 26)
	npc.skill_offset_unarmed = _u8(dnam, 27)
	npc.race_form_id = _u32(_subrecord(raw, "RNAM")); npc.race = get_base(npc.race_form_id) as RaceBase
	npc.class_form_id = _u32(_subrecord(raw, "CNAM")); npc.actor_class = get_base(npc.class_form_id) as ClassBase
	npc.head_parts.clear()
	for part_data in _all_subrecords(raw, "PNAM"):
		var head_part := get_base(_u32(part_data)) as HeadPartBase
		if head_part != null: npc.head_parts.append(head_part)
	npc.hair_form_id = _u32(_subrecord(raw, "HNAM")); npc.hair = get_base(npc.hair_form_id) as HairBase
	npc.hair_length = _f32(_subrecord(raw, "LNAM"))
	var hclr := _subrecord(raw, "HCLR")
	npc.hair_color = Color8(_u8(hclr, 0), _u8(hclr, 1), _u8(hclr, 2)) if hclr.size() >= 3 else Color.BLACK
	npc.eyes_form_id = _u32(_subrecord(raw, "ENAM")); npc.eyes = get_base(npc.eyes_form_id) as EyesBase
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
	npc.unknown_nam5 = _u16(_subrecord(raw, "NAM5"))
	var nam6 := _subrecord(raw, "NAM6")
	npc.height = _f32(nam6) if not nam6.is_empty() else 1.0
	npc.weight = _f32(_subrecord(raw, "NAM7"))
	npc.body_part_data = get_base(NpcBase.DEFAULT_HUMAN_BODY_PART_DATA_FORM_ID) as BodyPartDataBase

func _populate_creature(result: CreatureBase, raw: Dictionary) -> void:
	_populate_actor(result, raw)
	var data := _subrecord(raw, "DATA")
	result.creature_type = _u8(data, 0)
	result.combat_skill = _u8(data, 1)
	result.magic_skill = _u8(data, 2)
	result.stealth_skill = _u8(data, 3)
	result.health = _i16(data, 4)
	result.damage = _i16(data, 8)
	result.strength = _u8(data, 10)
	result.perception = _u8(data, 11)
	result.endurance = _u8(data, 12)
	result.charisma = _u8(data, 13)
	result.intelligence = _u8(data, 14)
	result.agility = _u8(data, 15)
	result.luck = _u8(data, 16)
	result.attack_reach = _u8(_subrecord(raw, "RNAM"))
	result.melee_weapon_list_form_id = _u32(_subrecord(raw, "LNAM"))
	result.melee_weapon_list = get_base(result.melee_weapon_list_form_id) as FormListBase
	# Bethesda asset paths are commonly stored with backslashes. Normalize only
	# while extracting the directory; the resolved values retain the project's
	# established backslash path convention.
	var model_directory := result.model_path.replace("\\", "/").get_base_dir()
	result.model_list = PackedStringArray()
	result.model_list_paths = PackedStringArray()
	for nifz in _all_subrecords(raw, "NIFZ"):
		for filename in _zero_terminated_strings(nifz):
			result.model_list.append(filename)
			result.model_list_paths.append(_join_creature_asset_path(model_directory, filename))
	result.model_list_textures = _subrecord(raw, "NIFT")
	result.body_part_data_form_id = _u32(_subrecord(raw, "PNAM"))
	result.body_part_data = get_base(result.body_part_data_form_id) as BodyPartDataBase
	result.turning_speed = _f32(_subrecord(raw, "TNAM"))
	var bnam := _subrecord(raw, "BNAM")
	result.base_scale = _f32(bnam) if not bnam.is_empty() else 1.0
	result.foot_weight = _f32(_subrecord(raw, "WNAM"))
	result.sound_level = _u32(_subrecord(raw, "NAM5"))
	result.impact_dataset_form_id = _u32(_subrecord(raw, "CNAM"))
	result.impact_dataset = get_base(result.impact_dataset_form_id) as ImpactDatasetBase
	result.inherits_sounds_from_form_id = _u32(_subrecord(raw, "CSCR"))
	result.inherits_sounds_from = get_base(result.inherits_sounds_from_form_id) as CreatureBase
	result.sounds.clear()
	var sound: CreatureSoundCollection = null
	for subrecord in raw.get("subrecords", []):
		var tag := String(subrecord.get("type", ""))
		var bytes: PackedByteArray = subrecord.get("data", PackedByteArray())
		if tag == "CSDT":
			sound = CreatureSoundCollection.new()
			sound.sound_type = _u32(bytes)
			result.sounds.append(sound)
		elif tag == "CSDI" and sound != null:
			sound.sound_form_id = _u32(bytes)
			sound.sound = get_base(sound.sound_form_id) as SoundBase
		elif tag == "CSDC" and sound != null:
			sound.chance = _u8(bytes)

## A record's xEdit "Items": each CNTO with the COED that may follow it.
func _initial_items(raw: Dictionary) -> Array[InitialItemCollection]:
	var items: Array[InitialItemCollection] = []
	var current: InitialItemCollection = null
	for subrecord in raw.get("subrecords", []):
		var tag := String(subrecord.get("type", ""))
		var data: PackedByteArray = subrecord.get("data", PackedByteArray())
		if tag == "CNTO" and data.size() >= 8:
			current = InitialItemCollection.new()
			current.item_form_id = _u32(data)
			current.item = get_base(current.item_form_id)
			current.count = _i32(data, 4)
			items.append(current)
		elif tag == "COED" and current != null and data.size() >= 12:
			current.owner_form_id = _u32(data)
			current.owner = get_base(current.owner_form_id)
			if current.owner is NpcBase:
				current.global_variable_form_id = _u32(data, 4)
				current.global_variable = get_base(current.global_variable_form_id) as GlobalBase
			elif current.owner is FactionBase:
				current.required_rank = _i32(data, 4)
			current.condition = _f32(data, 8)
		elif tag != "COED":
			current = null
	return items

## A record's DEST collection and its stages; null when it has none.
func _destruction(raw: Dictionary) -> DestructionCollection:
	var dest := _subrecord(raw, "DEST")
	if dest.is_empty():
		return null
	var destruction := DestructionCollection.new()
	destruction.health = _i32(dest)
	destruction.vats_targetable = (_u8(dest, 5) & 0x01) != 0
	var stage: DestructionStageCollection = null
	for subrecord in raw.get("subrecords", []):
		var tag := String(subrecord.get("type", ""))
		var data: PackedByteArray = subrecord.get("data", PackedByteArray())
		match tag:
			"DSTD":
				stage = DestructionStageCollection.new()
				stage.health_percent = _u8(data, 0)
				stage.index = _u8(data, 1)
				stage.damage_stage = _u8(data, 2)
				stage.flags = _u8(data, 3)
				stage.self_damage_per_second = _i32(data, 4)
				stage.explosion_form_id = _u32(data, 8)
				stage.explosion = get_base(stage.explosion_form_id) as ExplosionBase
				stage.debris_form_id = _u32(data, 12)
				stage.debris = get_base(stage.debris_form_id) as DebrisBase
				stage.debris_count = _i32(data, 16)
				destruction.stages.append(stage)
			"DMDL":
				if stage != null: stage.model_path = _string(data)
			"DMDT":
				if stage != null: stage.model_info = data
			"DSTF":
				stage = null
	return destruction

func _populate_body_part_data(result: BodyPartDataBase, raw: Dictionary) -> void:
	result.skeleton_model_path = _string(_subrecord(raw, "MODL"))
	result.ragdoll_form_id = _u32(_subrecord(raw, "RAGA"))
	result.parts.clear()
	var current: BodyPartCollection = null
	for subrecord in raw.get("subrecords", []):
		var tag := String(subrecord.get("type", ""))
		var data: PackedByteArray = subrecord.get("data", PackedByteArray())
		if tag == "BPTN":
			if current != null:
				result.parts.append(current)
			current = BodyPartCollection.new()
			current.part_name = _string(data)
		elif tag == "BPNN":
			# BPTD permits an unnamed collection, which begins at BPNN. A second
			# BPNN therefore begins the next collection if the current one is full.
			if current == null or not current.part_node.is_empty():
				if current != null:
					result.parts.append(current)
				current = BodyPartCollection.new()
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

func _populate_body_part_numeric_data(part: BodyPartCollection, data: PackedByteArray, body_part_data: BodyPartDataBase) -> void:
	part.raw_bpnd = data.duplicate()
	if data.size() != 84:
		body_part_data.diagnostics.append("BPTD 0x%08X BPND has %d bytes; expected 84" % [body_part_data.form_id, data.size()])
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

## The script of the Base or Reference class `script_name` (TYPE_TO_BASE,
## TYPE_TO_REFERENCE), from its subfolder of ResourceRoot.
func _resource_script(script_name: String) -> Script:
	var folder := ReferenceFolder if script_name.ends_with("Reference") else BaseFolder
	return load(ResourceRoot + folder + _snake_case(script_name) + ".gd")

func _snake_case(value: String) -> String:
	var out := ""
	for i in value.length():
		var c := value[i]
		if i > 0 and c == c.to_upper() and c != c.to_lower(): out += "_"
		out += c.to_lower()
	return out
