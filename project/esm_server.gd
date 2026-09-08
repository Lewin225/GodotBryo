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
		return null
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
		var adata := _subrecord(raw, "DATA"); armor.value = _i32(adata); armor.weight = _f32(adata, 4); armor.armor_rating = _i32(_subrecord(raw, "DNAM"))
	elif result is DoorBase:
		(result as DoorBase).model_path = _string(_subrecord(raw, "MODL"))
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

func _parse_authored_id(id: String) -> int:
	var suffix := id.trim_prefix("authored:")
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
