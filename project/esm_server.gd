@tool
extends Node

signal esm_ready
signal failed(message: String)

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
	"STAT": "StaticBase", "CREA": "CreatureBase"
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
var _record_index: Array = []
var _game_session = null
var _load_thread: Thread
var _load_result: Dictionary = {}
var state := "loading"
var _pending_rehydrates: Array[EsmBase] = []

func _ready() -> void:
	_load_thread = Thread.new()
	_load_thread.start(_open_reader_background)

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
	return {"ok": true, "reader": background_reader, "record_index": background_reader.get_record_index()}

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
	var form_id := _parse_authored_id(instance_id)
	if form_id == 0:
		return null
	var owner: Dictionary = reader.find_cell_containing_ref(form_id)
	if owner.is_empty():
		return null
	var cell_id := int(owner.get("cell_form_id", 0))
	for placement in reader.get_cell_references(cell_id) + reader.get_cell_actors(cell_id):
		if int(placement.get("refr_form_id", 0)) == form_id:
			return _reference_from_placement(placement, instance_id, cell_id)
	return null

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

func _reference_from_placement(placement: Dictionary, id: String, cell_id: int) -> EsmReference:
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
	result.current_cell_form_id = cell_id
	result.position = placement.get("position", Vector3.ZERO)
	result.rotation = placement.get("rotation", Vector3.ZERO)
	result.scale = float(placement.get("scale", 1.0))
	if result is DoorReference:
		var door_ref: DoorReference = result
		door_ref.has_teleport_destination = bool(placement.get("has_xtel", false))
		door_ref.teleport_destination_refr_form_id = int(placement.get("dest_refr_form_id", 0))
		door_ref.teleport_position = placement.get("dest_position", Vector3.ZERO)
		door_ref.teleport_rotation = placement.get("dest_rotation", Vector3.ZERO)
		if door_ref.teleport_destination_refr_form_id != 0 and reader != null:
			var destination_owner: Dictionary = reader.find_cell_containing_ref(door_ref.teleport_destination_refr_form_id)
			door_ref.teleport_destination_cell_form_id = int(destination_owner.get("cell_form_id", 0))
		var ref_raw: Dictionary = reader.get_record_data(int(placement.get("refr_form_id", 0))) if reader != null else {}
		var lock_data := _subrecord(ref_raw, "XLOC")
		if lock_data.size() >= 9:
			door_ref.lock_level = _u8(lock_data)
			door_ref.lock_key_form_id = _u32(lock_data, 4)
			door_ref.lock_key = get_base(door_ref.lock_key_form_id) as KeyBase
			door_ref.lock_flags = _u8(lock_data, 8)
			door_ref.is_locked = door_ref.lock_level > 0 or door_ref.lock_key_form_id != 0
			door_ref.is_leveled_lock = (door_ref.lock_flags & 0x04) != 0
		var activation := _subrecord(ref_raw, "XACT")
		if activation.size() >= 4:
			door_ref.activation_flags = _u32(activation)
		door_ref.is_open_by_default = _subrecord_present(ref_raw, "ONAM") or (door_ref.activation_flags & 0x08) != 0
		door_ref.is_open = door_ref.is_open_by_default
		var teleport := _subrecord(ref_raw, "XTEL")
		if teleport.size() >= 32:
			door_ref.teleport_no_alarm = (_u32(teleport, 28) & 0x01) != 0
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
	if result is WeaponBase:
		var weapon: WeaponBase = result
		weapon.model_path = _string(_subrecord(raw, "MODL"))
		var data := _subrecord(raw, "DATA")
		weapon.value = _i32(data); weapon.health = _i32(data, 4); weapon.weight = _f32(data, 8)
		weapon.base_damage = _u16(data, 12); weapon.clip_size = _u8(data, 14)
		weapon.first_person_form_id = _u32(_subrecord(raw, "WNAM"))
		weapon.equipment_type = _u32(_subrecord(raw, "ETYP")); weapon.animation_type = _u32(_subrecord(raw, "DNAM"))
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
		npc.race_form_id = _u32(_subrecord(raw, "RNAM")); npc.race = get_base(npc.race_form_id) as RaceBase
		npc.hair_form_id = _u32(_subrecord(raw, "HNAM")); npc.hair = get_base(npc.hair_form_id) as HairBase
		npc.eyes_form_id = _u32(_subrecord(raw, "ENAM")); npc.eyes = get_base(npc.eyes_form_id) as EyesBase
		npc.class_form_id = _u32(_subrecord(raw, "CNAM")); npc.actor_class = get_base(npc.class_form_id) as ClassBase
		npc.packages.clear()
		for package_data in _all_subrecords(raw, "PKID"):
			var package_base := get_base(_u32(package_data)) as PackageBase
			if package_base != null: npc.packages.append(package_base)
	elif result is RaceBase:
		_populate_race(result as RaceBase, raw)
	elif result is ArmorBase:
		var armor: ArmorBase = result
		armor.male_biped_model = _string(_subrecord(raw, "MODL")); armor.male_world_model = _string(_subrecord(raw, "MOD2"))
		armor.female_biped_model = _string(_subrecord(raw, "MOD3")); armor.female_world_model = _string(_subrecord(raw, "MOD4"))
		armor.model_path = armor.male_world_model
		var adata := _subrecord(raw, "DATA"); armor.value = _i32(adata); armor.weight = _f32(adata, 4); armor.armor_rating = _i32(_subrecord(raw, "DNAM"))
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
		container.items.clear()
		var item_index := 0
		for item_data in _all_subrecords(raw, "CNTO"):
			if item_data.size() < 8: continue
			var entry := InventoryEntryResource.new()
			entry.item_form_id = _u32(item_data)
			entry.count = _i32(item_data, 4)
			entry.source_form_id = entry.item_form_id
			entry.source_index = item_index
			entry.instance_id = "authored:%08X:%d" % [entry.item_form_id, item_index]
			entry.item_base = get_base(entry.item_form_id)
			container.items.append(entry)
			item_index += 1
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

func _string(data: PackedByteArray) -> String:
	var end := data.size()
	for i in data.size():
		if data[i] == 0: end = i; break
	return data.slice(0, end).get_string_from_ascii()

func _u32(data: PackedByteArray, offset := 0) -> int:
	return int(data.decode_u32(offset)) if data.size() >= offset + 4 else 0
func _u16(data: PackedByteArray, offset := 0) -> int:
	return int(data.decode_u16(offset)) if data.size() >= offset + 2 else 0
func _u8(data: PackedByteArray, offset := 0) -> int:
	return int(data[offset]) if data.size() > offset else 0
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
