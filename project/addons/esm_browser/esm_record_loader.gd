class_name ESMRecordResourceLoader
extends ResourceFormatLoader

const FactoryScript = preload("res://gamebryo/esm_resource_factory.gd")

## Keep these untyped: editor plugins can be parsed before the GDExtension's
## EsmReader global class is registered during a clean editor startup.
var reader
var factory

func configure(esm_reader) -> void:
	reader = esm_reader
	factory = FactoryScript.new(reader)

func _get_recognized_extensions() -> PackedStringArray:
	return ["nvrecord"]

func _recognize_path(path: String, _type: StringName) -> bool:
	return path.to_lower().ends_with(".nvrecord")

func _get_resource_type(_path: String) -> String:
	var tag := _record_type_from_path(_path)
	return {
		"NPC_": "NpcRecord",
		"RACE": "RaceRecord",
		"HAIR": "HairRecord",
		"EYES": "EyesRecord",
		"ARMO": "ArmorRecord",
		"ARMA": "ArmorAddonRecord",
		"WEAP": "WeaponRecord",
		"ALCH": "AlchemyRecord",
		"LVLI": "LeveledItemRecord",
		"PACK": "PackageRecord",
		"CLAS": "ClassRecord",
	}.get(tag, "EsmRecordResource")

func _handles_type(type: StringName) -> bool:
	return type in [
		&"Resource", &"EsmRecordResource", &"NpcRecord", &"RaceRecord",
		&"HairRecord", &"EyesRecord", &"ArmorRecord", &"ArmorAddonRecord",
		&"WeaponRecord", &"AlchemyRecord", &"LeveledItemRecord",
		&"PackageRecord", &"ClassRecord",
	]

func _exists(path: String) -> bool:
	return path.to_lower().ends_with(".nvrecord") and FileAccess.file_exists(path)

func _load(path: String, _original_path: String, _use_sub_threads: bool, _cache_mode: int) -> Variant:
	var parts := path.replace("\\", "/").split("/")
	if parts.size() < 2 or factory == null:
		return ERR_FILE_NOT_FOUND
	var type_tag := _record_type_from_path(path)
	var filename := parts[parts.size() - 1].trim_suffix(".nvrecord")
	var underscore := filename.rfind("_")
	if underscore < 0:
		return ERR_FILE_CORRUPT
	var form_id := ("0x" + filename.substr(underscore + 1)).hex_to_int()
	var resource = factory.load_record(type_tag, form_id)
	return resource if resource != null else ERR_FILE_NOT_FOUND

func _record_type_from_path(path: String) -> String:
	var parts := path.replace("\\", "/").split("/")
	return parts[parts.size() - 2].to_upper() if parts.size() >= 2 else ""
