extends Node

## Census of what could animate furniture use: KF files under
## meshes\characters\ whose path mentions sit, chair, bench, stool, couch,
## sleep, bed, lean or furniture; and IDLE records whose MODL or editor ID
## does, with their DATA section byte and conditions' functions.

const WORDS := ["sit", "chair", "bench", "stool", "couch", "sleep", "bed", "lean", "furniture"]

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var files: PackedStringArray = ArchiveServer.list_files_with_prefix("meshes\\characters\\")
	var by_folder := {}
	for path in files:
		var lower := path.to_lower()
		if not lower.ends_with(".kf"):
			continue
		if not _matches(lower.get_file()):
			continue
		var folder := lower.get_base_dir()
		if not by_folder.has(folder):
			by_folder[folder] = []
		by_folder[folder].append(lower.get_file())
	for folder in by_folder:
		print("%s (%d): %s" % [folder, by_folder[folder].size(), ", ".join(by_folder[folder])])
	print("--- IDLE records")
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) != "IDLE":
			continue
		var editor_id := String(row.get("editor_id", "")).to_lower()
		var model := ""
		var raw: Dictionary = EsmServer.reader.get_record_data(int(row["form_id"]))
		for sub in raw.get("subrecords", []):
			if sub.get("type") == "MODL":
				model = (sub["data"] as PackedByteArray).get_string_from_ascii()
		if not _matches(editor_id) and not _matches(model.to_lower().get_file()):
			continue
		print("%s  %s" % [row.get("editor_id", ""), model])
	get_tree().quit()

func _matches(name: String) -> bool:
	for word in WORDS:
		if name.contains(word):
			return true
	return false
