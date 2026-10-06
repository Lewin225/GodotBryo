extends Node

## Census: every .kf under meshes/ whose bytes name Camera1st (a track target
## string), grouped by folder.
func _ready() -> void:
	await get_tree().process_frame
	var needle := "Camera1st".to_utf8_buffer()
	var total := 0
	var hits: Array[String] = []
	for path in ArchiveServer.list_files_with_prefix("meshes/"):
		var file := String(path)
		if not file.ends_with(".kf"):
			continue
		total += 1
		var result := ArchiveServer.read(file)
		var data: PackedByteArray = result.get("data", PackedByteArray())
		if _contains(data, needle):
			hits.append(file)
	print("kf total %d, naming Camera1st %d" % [total, hits.size()])
	hits.sort()
	for file in hits:
		print("  ", file)
	get_tree().quit()

func _contains(data: PackedByteArray, needle: PackedByteArray) -> bool:
	return data.size() > 0 and _find_bytes(data, needle)

func _find_bytes(data: PackedByteArray, needle: PackedByteArray) -> bool:
	var first := needle[0]
	var index := data.find(first)
	while index != -1:
		if index + needle.size() <= data.size() and data.slice(index, index + needle.size()) == needle:
			return true
		index = data.find(first, index + 1)
	return false
