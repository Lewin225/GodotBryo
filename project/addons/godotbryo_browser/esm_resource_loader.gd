@tool
class_name GodotBryoResourceLoader
extends ResourceFormatLoader

func _get_recognized_extensions() -> PackedStringArray:
	return ["nvbase"]

func _recognize_path(path: String, _type: StringName) -> bool:
	return path.to_lower().begins_with("esm://") or path.to_lower().ends_with(".nvbase")

func _get_resource_type(_path: String) -> String:
	return "EsmBase"

func _handles_type(type: StringName) -> bool:
	return type in [&"Resource", &"EsmBase"]

func _exists(path: String) -> bool:
	return _recognize_path(path, &"")

func _load(path: String, _original_path: String, _use_sub_threads: bool, _cache_mode: int) -> Variant:
	var form_id := 0
	if path.to_lower().begins_with("esm://"):
		var server = Engine.get_main_loop().root.get_node_or_null("EsmServer")
		var result = server.get_base_from_uri(path) if server != null else null
		return result if result != null else ERR_FILE_NOT_FOUND
	else:
		var stem := path.get_file().trim_suffix(".nvbase")
		var underscore := stem.rfind("_")
		if underscore < 0: return ERR_FILE_CORRUPT
		form_id = ("0x" + stem.substr(underscore + 1)).hex_to_int()
	var server = Engine.get_main_loop().root.get_node_or_null("EsmServer")
	var result = server.get_base(form_id) if server != null else null
	return result if result != null else ERR_FILE_NOT_FOUND
