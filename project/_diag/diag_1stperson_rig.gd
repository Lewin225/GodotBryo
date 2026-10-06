extends Node

## The first-person rig: skeleton.nif's node names; the _1stperson KF names
## grouped by prefix; and every meshes/characters NIF whose name suggests
## first-person arms or hands.
func _ready() -> void:
	await get_tree().process_frame
	var kf_prefixes := {}
	var hand_meshes: Array[String] = []
	for path in ArchiveServer.list_files_with_prefix("meshes/"):
		var file := String(path)
		var lower := file.to_lower()
		if lower.begins_with("meshes/characters/_1stperson/") and lower.ends_with(".kf"):
			var name := lower.get_file().get_basename()
			var prefix := name.substr(0, 4)
			if not kf_prefixes.has(prefix):
				kf_prefixes[prefix] = []
			kf_prefixes[prefix].append(name)
		elif lower.ends_with(".nif") and lower.begins_with("meshes/characters/") and (lower.contains("hand") or lower.contains("upperbody") or lower.contains("arm") and not lower.contains("armor")):
			hand_meshes.append(file)
	var keys := kf_prefixes.keys()
	keys.sort()
	for prefix in keys:
		var names: Array = kf_prefixes[prefix]
		print("%4d %s*: %s" % [names.size(), prefix, ", ".join(names.slice(0, 8))])
	print("character NIFs naming hand/upperbody/arm: %d" % hand_meshes.size())
	hand_meshes.sort()
	for file in hand_meshes.slice(0, 40):
		print("  ", file)
	get_tree().quit()
