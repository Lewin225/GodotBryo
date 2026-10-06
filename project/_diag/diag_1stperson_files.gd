extends Node

## Lists every archive file under meshes/characters/_1stperson/ (and any
## meshes path naming 1stperson elsewhere), grouped by folder and extension.
func _ready() -> void:
	await get_tree().process_frame
	var groups := {}
	var elsewhere: Array[String] = []
	for path in ArchiveServer.list_files_with_prefix("meshes/"):
		var file := String(path)
		var lower := file.to_lower()
		if lower.begins_with("meshes/characters/_1stperson/"):
			var key := "%s *.%s" % [file.get_base_dir(), file.get_extension()]
			groups[key] = int(groups.get(key, 0)) + 1
		elif lower.contains("1stperson") or lower.contains("1st_person") or lower.contains("firstperson"):
			elsewhere.append(file)
	var keys := groups.keys()
	keys.sort()
	for key in keys:
		print("%5d %s" % [groups[key], key])
	print("elsewhere naming 1stperson: %d" % elsewhere.size())
	elsewhere.sort()
	for file in elsewhere.slice(0, 40):
		print("  ", file)
	get_tree().quit()
