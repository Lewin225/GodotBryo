class_name EsmResourceFactory
extends RefCounted

const GenericItemRecordScript := preload("res://gamebryo/generic_item_record.gd")

## Session-scoped, in-memory ESM -> typed Godot Resource factory. Resources
## are inspectable in the editor and intentionally are not written to disk;
## a persistent cache can replace this implementation behind the same API.
## The native EsmReader class may register after the editor's first script
## scan, so keep this boundary dynamically typed.
var reader
var _cache: Dictionary = {}

func _init(esm_reader) -> void:
	reader = esm_reader

func load_npc(form_id: int) -> NpcRecord:
	return _load_typed("NPC_", form_id, _build_npc)

func load_race(form_id: int) -> RaceRecord:
	return _load_typed("RACE", form_id, _build_race)

func load_hair(form_id: int) -> HairRecord:
	return _load_typed("HAIR", form_id, _build_hair)

func load_eyes(form_id: int) -> EyesRecord:
	return _load_typed("EYES", form_id, _build_eyes)

func load_armor(form_id: int) -> ArmorRecord:
	return _load_typed("ARMO", form_id, _build_armor)

func load_armor_addon(form_id: int) -> ArmorAddonRecord:
	return _load_typed("ARMA", form_id, _build_armor_addon)

func load_biped_model_list(form_id: int) -> BipedModelListResource:
	return _load_typed("FLST", form_id, _build_biped_model_list)

func load_weapon(form_id: int) -> WeaponRecord:
	return _load_typed("WEAP", form_id, _build_weapon)

func load_alchemy(form_id: int) -> EsmRecordResource:
	return _load_typed("ALCH", form_id, _build_alchemy)

func load_leveled_item(form_id: int) -> EsmRecordResource:
	return _load_typed("LVLI", form_id, _build_leveled_item)

func load_generic_item(type_tag: String, form_id: int) -> EsmRecordResource:
	if not ["AMMO", "ALCH", "BOOK", "CCRD", "CMNY", "KEYM", "MISC"].has(type_tag):
		return null
	return _load_typed(type_tag, form_id, _build_generic_item)

func load_record(type_tag: String, form_id: int) -> EsmRecordResource:
	match type_tag:
		"NPC_": return load_npc(form_id)
		"RACE": return load_race(form_id)
		"HAIR": return load_hair(form_id)
		"EYES": return load_eyes(form_id)
		"ARMO": return load_armor(form_id)
		"ARMA": return load_armor_addon(form_id)
		"FLST": return load_biped_model_list(form_id)
		"WEAP": return load_weapon(form_id)
		"ALCH": return load_alchemy(form_id)
		"AMMO", "BOOK", "CCRD", "CMNY", "KEYM", "MISC": return load_generic_item(type_tag, form_id)
		"LVLI": return load_leveled_item(form_id)
		_: return null

func _key(type_tag: String, form_id: int) -> String:
	return "%s:%08X" % [type_tag, form_id]

func _load_typed(type_tag: String, form_id: int, builder: Callable) -> EsmRecordResource:
	if form_id == 0:
		return null
	var key := _key(type_tag, form_id)
	if _cache.has(key):
		return _cache[key]
	var raw: Dictionary = reader.get_record_data(form_id)
	if raw.is_empty() or String(raw.get("record_type", "")) != type_tag:
		return null
	var result: EsmRecordResource = builder.call(raw)
	_cache[key] = result
	return result

func _base(raw: Dictionary, result: EsmRecordResource) -> void:
	result.form_id = int(raw.get("form_id", 0))
	result.record_type = String(raw.get("record_type", ""))
	result.source_uri = "esm://FalloutNV.esm/%s/%08X" % [result.record_type, result.form_id]
	result.raw_subrecords.clear()
	for subrecord in raw.get("subrecords", []):
		result.raw_subrecords.append(subrecord)
	result.editor_id = _string(result.subrecord_data("EDID"))

func _string(data: PackedByteArray) -> String:
	if data.is_empty(): return ""
	var end := data.size()
	for i in data.size():
		if data[i] == 0:
			end = i
			break
	return data.slice(0, end).get_string_from_ascii()

func _u32(data: PackedByteArray, offset := 0) -> int:
	if data.size() < offset + 4: return 0
	return int(data.decode_u32(offset))

func _u16(data: PackedByteArray, offset := 0) -> int:
	if data.size() < offset + 2: return 0
	return int(data.decode_u16(offset))

func _u8(data: PackedByteArray, offset := 0) -> int:
	if data.size() <= offset: return 0
	return int(data[offset])

func _i32(data: PackedByteArray, offset := 0) -> int:
	if data.size() < offset + 4: return 0
	return int(data.decode_s32(offset))

func _f32(data: PackedByteArray, offset := 0) -> float:
	if data.size() < offset + 4: return 0.0
	return data.decode_float(offset)

func _model_fields(result: Object) -> void:
	result.male_biped_model = _string(result.subrecord_data("MODL"))
	result.male_world_model = _string(result.subrecord_data("MOD2"))
	result.female_biped_model = _string(result.subrecord_data("MOD3"))
	result.female_world_model = _string(result.subrecord_data("MOD4"))

func _build_npc(raw: Dictionary) -> NpcRecord:
	var result := NpcRecord.new()
	_base(raw, result)
	result.full_name = _string(result.subrecord_data("FULL"))
	result.model_path = _string(result.subrecord_data("MODL"))
	var acbs := result.subrecord_data("ACBS")
	result.acbs_flags = _u32(acbs)
	result.is_female = (result.acbs_flags & 1) != 0
	result.race = load_race(_u32(result.subrecord_data("RNAM")))
	result.hair = load_hair(_u32(result.subrecord_data("HNAM")))
	result.eyes = load_eyes(_u32(result.subrecord_data("ENAM")))
	result.actor_class = load_class(_u32(result.subrecord_data("CNAM")))
	var face := FaceGenData.new()
	face.fggs = result.subrecord_data("FGGS")
	face.fgga = result.subrecord_data("FGGA")
	face.fgts = result.subrecord_data("FGTS")
	if reader.has_method("get_facegen_data"):
		var decoded: Dictionary = reader.get_facegen_data(result.form_id)
		face.fggs_values = decoded.get("fggs_values", PackedFloat32Array())
		face.fgga_values = decoded.get("fgga_values", PackedFloat32Array())
		face.fgts_values = decoded.get("fgts_values", PackedFloat32Array())
		face.fggs_decoded = bool(decoded.get("fggs_decoded", false))
		face.fgga_decoded = bool(decoded.get("fgga_decoded", false))
		face.fgts_decoded = bool(decoded.get("fgts_decoded", false))
		face.diagnostics = decoded.get("diagnostics", PackedStringArray())
	result.face_gen = face
	for data in result.all_subrecord_data("PKID"):
		var package := load_package(_u32(data))
		if package != null:
			result.packages.append(package)
	for data in result.all_subrecord_data("CNTO"):
		if data.size() >= 8:
			var entry := InventoryEntryResource.new()
			entry.item_form_id = _u32(data)
			entry.count = _u32(data, 4)
			entry.item_record = _load_inventory_item(entry.item_form_id)
			result.inventory.append(entry)
	return result

func _load_inventory_item(form_id: int) -> EsmRecordResource:
	var raw: Dictionary = reader.get_record_data(form_id)
	match String(raw.get("record_type", "")):
		"ARMO": return load_armor(form_id)
		"WEAP": return load_weapon(form_id)
		"ALCH": return load_alchemy(form_id)
		"LVLI": return load_leveled_item(form_id)
		"AMMO", "ALCH", "BOOK", "CCRD", "CMNY", "KEYM", "MISC": return load_generic_item(String(raw.get("record_type", "")), form_id)
		_: return null

func _build_alchemy(raw: Dictionary) -> EsmRecordResource:
	var result = preload("res://gamebryo/alchemy_record.gd").new()
	_base(raw, result)
	result.full_name = _string(result.subrecord_data("FULL"))
	result.inventory_icon = _string(result.subrecord_data("ICON"))
	result.message_icon = _string(result.subrecord_data("MICO"))
	var item_data = reader.get_item_data(result.form_id)
	if not item_data.is_empty():
		result.value = int(item_data.get("value", 0))
		result.weight = float(item_data.get("weight", 0.0))
	for effect_id in result.all_subrecord_data("EFID"):
		result.effect_form_ids.append(_u32(effect_id))
	return result

func _build_leveled_item(raw: Dictionary) -> EsmRecordResource:
	var result = preload("res://gamebryo/leveled_item_record.gd").new()
	_base(raw, result)
	for data in result.all_subrecord_data("LVLO"):
		if data.size() < 8:
			continue
		result.entries.append({"level": _u16(data), "flags": _u16(data, 2), "form_id": _u32(data, 4), "raw": data})
	return result

func _build_generic_item(raw: Dictionary) -> EsmRecordResource:
	var result = GenericItemRecordScript.new()
	_base(raw, result)
	result.full_name = _string(result.subrecord_data("FULL"))
	result.inventory_icon = _string(result.subrecord_data("ICON"))
	result.message_icon = _string(result.subrecord_data("MICO"))
	var item_data = reader.get_item_data(result.form_id)
	if not item_data.is_empty():
		result.value = int(item_data.get("value", 0))
		result.weight = float(item_data.get("weight", 0.0))
	return result

func _build_armor_addon(raw: Dictionary) -> ArmorAddonRecord:
	var result := ArmorAddonRecord.new()
	_base(raw, result)
	result.full_name = _string(result.subrecord_data("FULL"))
	result.biped_flags = _u32(result.subrecord_data("BMDT"))
	var bnam := result.subrecord_data("BNAM")
	result.general_flags = _u32(bnam)
	result.equipment_type = _u32(result.subrecord_data("ETYP"))
	_model_fields(result)
	return result

func _build_biped_model_list(raw: Dictionary) -> BipedModelListResource:
	var result := BipedModelListResource.new()
	_base(raw, result)
	for data in result.all_subrecord_data("LNAM"):
		var form_id := _u32(data)
		var addon := load_armor_addon(form_id)
		if addon != null:
			result.entries.append(addon)
		else:
			result.unresolved_form_ids.append(form_id)
	return result

func _build_armor(raw: Dictionary) -> ArmorRecord:
	var result := ArmorRecord.new()
	_base(raw, result)
	result.full_name = _string(result.subrecord_data("FULL"))
	result.biped_flags = _u32(result.subrecord_data("BMDT"))
	result.equipment_type = _u32(result.subrecord_data("ETYP"))
	_model_fields(result)
	var data := result.subrecord_data("DATA")
	result.value = _i32(data)
	result.weight = _f32(data, 4)
	var rating := result.subrecord_data("DNAM")
	result.armor_rating = _i32(rating)
	var bipl := _u32(result.subrecord_data("BIPL"))
	result.biped_model_list = load_biped_model_list(bipl)
	return result

func _build_weapon(raw: Dictionary) -> WeaponRecord:
	var result := WeaponRecord.new()
	_base(raw, result)
	result.full_name = _string(result.subrecord_data("FULL"))
	result.model_path = _string(result.subrecord_data("MODL"))
	# FNV's first-person base model is WNAM (a STAT FormID).  1MOD is not
	# present in the shipped base WEAP records; WNM1..WNM7 are its modded
	# first-person variants and remain available through raw_subrecords.
	result.first_person_form_id = _u32(result.subrecord_data("WNAM"))
	result.equipment_type = _u32(result.subrecord_data("ETYP"))
	var data := result.subrecord_data("DATA")
	result.value = _i32(data)
	result.health = _i32(data, 4)
	result.weight = _f32(data, 8)
	result.base_damage = _u16(data, 12)
	if data.size() >= 15:
		result.clip_size = int(data[14])
	var dnam := result.subrecord_data("DNAM")
	result.animation_type = _u32(dnam)
	result.animation_family = _weapon_animation_family(result.animation_type)
	result.animation_flags_1 = _u8(dnam, 12)
	result.grip_animation = _u8(dnam, 13)
	result.ammo_use = _u8(dnam, 14)
	result.reload_animation = _u8(dnam, 15)
	result.attack_animation = _u8(dnam, 41)
	result.animation_flags_2 = _u32(dnam, 56)
	result.biped_model_list = load_biped_model_list(_u32(result.subrecord_data("BIPL")))
	return result

func _weapon_animation_family(animation_type: int) -> String:
	match animation_type:
		WeaponRecord.ANIMATION_HAND_TO_HAND: return "h2h"
		WeaponRecord.ANIMATION_ONE_HANDED_MELEE: return "1hm"
		WeaponRecord.ANIMATION_TWO_HANDED_MELEE: return "2hm"
		WeaponRecord.ANIMATION_ONE_HANDED_BALLISTIC, WeaponRecord.ANIMATION_ONE_HANDED_ENERGY: return "1hp"
		WeaponRecord.ANIMATION_TWO_HANDED_BALLISTIC: return "2hr"
		WeaponRecord.ANIMATION_TWO_HANDED_AUTOMATIC: return "2ha"
		WeaponRecord.ANIMATION_TWO_HANDED_ENERGY: return "2hr"
		WeaponRecord.ANIMATION_TWO_HANDED_HANDLE: return "2hh"
		WeaponRecord.ANIMATION_TWO_HANDED_LAUNCHER: return "2hl"
		WeaponRecord.ANIMATION_GRENADE_THROW: return "1gt"
		WeaponRecord.ANIMATION_LAND_MINE: return "1lm"
		WeaponRecord.ANIMATION_MINE_DROP: return "1md"
		WeaponRecord.ANIMATION_THROWN: return "1gt"
		_: return ""

func load_class(form_id: int) -> ClassRecord:
	return _load_typed("CLAS", form_id, _build_class)

func load_package(form_id: int) -> PackageRecord:
	return _load_typed("PACK", form_id, _build_package)

func _build_hair(raw: Dictionary) -> HairRecord:
	var result := HairRecord.new()
	_base(raw, result)
	result.full_name = _string(result.subrecord_data("FULL"))
	result.model_path = _string(result.subrecord_data("MODL"))
	result.icon_path = _string(result.subrecord_data("ICON"))
	result.flags = _u32(result.subrecord_data("DATA"))
	return result

func _build_eyes(raw: Dictionary) -> EyesRecord:
	var result := EyesRecord.new()
	_base(raw, result)
	result.full_name = _string(result.subrecord_data("FULL"))
	result.model_path = _string(result.subrecord_data("MODL"))
	result.icon_path = _string(result.subrecord_data("ICON"))
	return result

func _build_class(raw: Dictionary) -> ClassRecord:
	var result := ClassRecord.new()
	_base(raw, result)
	result.full_name = _string(result.subrecord_data("FULL"))
	return result

func _build_package(raw: Dictionary) -> PackageRecord:
	var result := PackageRecord.new()
	_base(raw, result)
	result.package_flags = _u32(result.subrecord_data("DATA"))
	return result

func _build_race(raw: Dictionary) -> RaceRecord:
	var result := RaceRecord.new()
	_base(raw, result)
	# The native, already verified body resolver remains the source for body
	# meshes until the complete RACE part parser is promoted to this factory.
	for female in [false, true]:
		var parts: Array = reader.get_race_body_parts(result.form_id, female)
		for item in parts:
			var part := RacePartResource.new()
			part.index = int(item.get("index", 0))
			part.model_path = String(item.get("model", ""))
			part.icon_path = String(item.get("icon", ""))
			if female:
				result.female_body_parts.append(part)
			else:
				result.male_body_parts.append(part)
		var head_parts: Array = reader.get_race_head_parts(result.form_id, female)
		for item in head_parts:
			var head := RacePartResource.new()
			head.index = int(item.get("index", 0))
			head.part_type = _race_head_part_type(head.index)
			head.model_path = String(item.get("model", ""))
			head.icon_path = String(item.get("icon", ""))
			if female:
				result.female_head_parts.append(head)
			else:
				result.male_head_parts.append(head)
	return result

func _race_head_part_type(index: int) -> String:
	# RACE head INDX meanings are the verified TES/FNV convention used by the
	# shipped human and ghoul records; the ears entry may be icon-only.
	return {
		0: "head",
		1: "ears",
		2: "mouth",
		3: "teeth_lower",
		4: "teeth_upper",
		5: "tongue",
		6: "eye_left",
		7: "eye_right",
	}.get(index, "head_part_%d" % index)
