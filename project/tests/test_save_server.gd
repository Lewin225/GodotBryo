extends Node

## SaveServer and JsonFolderBackend: a save written as a folder of JSON files
## and read back equal to the state it came from; the state applied and built
## again unchanged; a save needing a master that is not loaded refused; one
## from a changed master loaded with a warning; two saves differing only in
## the file whose state changed; a save refused while a move is queued.
## Saves go to user://test_save_server and are deleted after.

const SaveServerScript := preload("res://GodotBryo/Servers/SaveServer/save_server.gd")
const ROOT := "user://test_save_server"

var failures := 0

func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var saves: Node = SaveServerScript.new()
	add_child(saves)
	var backend := JsonFolderBackend.new(ROOT)
	saves.register_backend("json_folder", backend)
	for entry: Dictionary in backend.list():
		backend.delete(String(entry["save_id"]))

	var marker := EsmServer.find_reference_by_editor_id("VCG01PlayerStartMarkerREF")
	var player := EsmServer.get_player_reference()
	player.set_location(marker.current_space_form_id, marker.position)
	var vcg01 := EsmServer.find_quest_by_editor_id("VCG01")
	QuestServer.set_stage(vcg01, 0)
	var door := EsmServer.get_reference_by_form_id(0x0010901D) as DoorReference
	door.is_open = not door.is_open

	check(saves.save("test_a") == OK, "a save is written: %s" % ", ".join(saves.report))
	var folder := ROOT.path_join("test_a")
	var house_file := folder.path_join("esm_server/references/GSDocMitchellHouse.json")
	check(FileAccess.file_exists(folder.path_join("header.json")) and FileAccess.file_exists(folder.path_join("quest_server.json")) and FileAccess.file_exists(house_file),
			"the save is a folder: header.json, quest_server.json, esm_server/references/GSDocMitchellHouse.json")
	check(not DirAccess.dir_exists_absolute(folder + JsonFolderBackend.WRITING_SUFFIX), "no partly written folder is left")
	var built: Dictionary = saves.build_state()
	var read: Dictionary = saves.read_save("test_a")
	check(not read.is_empty() and saves.report.is_empty(), "the save reads back with nothing to report")
	check(_sections_differ(built, read).is_empty(), "the save reads back as the state it was made from: %s" % _sections_differ(built, read))

	# The game is paused around a load, as game.gd does, so no quest or
	# script runs between applying the save and building it again.
	get_tree().paused = true
	await saves.apply_state(read)
	check(saves.report.is_empty(), "applying it drops nothing")
	check(FileAccess.get_file_as_string(SaveServerScript.LOAD_REPORT_PATH).contains("Loaded test_a"), "the load report is written")
	check(_sections_differ(read, saves.build_state()).is_empty(), "the state built after applying it is the save: %s" % _sections_differ(read, saves.build_state()))
	get_tree().paused = false

	check(saves.save("test_a") == OK and saves.read_save("test_a").size() == read.size(), "saving over a save replaces it")

	var header_path := folder.path_join("header.json")
	var header: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(header_path))
	var masters: Array = header["masters"]
	(masters[0] as Dictionary)["size"] = int(masters[0]["size"]) + 1
	_write_json(header_path, header)
	check(not saves.read_save("test_a").is_empty() and saves.report.size() == 1 and saves.report[0].contains("has changed"),
			"a save from a changed master loads with a warning: %s" % ", ".join(saves.report))
	masters.append({"file": "DeadMoney.esm", "size": 1, "modified": 1})
	_write_json(header_path, header)
	check(saves.read_save("test_a").is_empty() and saves.report.back().contains("needs DeadMoney.esm"), "a save needing a master that is not loaded is refused: %s" % ", ".join(saves.report))

	check(saves.save("test_b") == OK, "a second save is written")
	QuestServer.set_stage(vcg01, 10)
	check(saves.save("test_c", "test_b") == OK, "a third save, from the second, is written")
	var changed := _changed_files(ROOT.path_join("test_b"), ROOT.path_join("test_c"))
	check(changed == ["header.json", "quest_server.json"], "two saves around a quest stage differ only in quest_server.json and header.json: %s" % [changed])
	check(saves.read_save("test_c")["header"]["parent"] == "test_b", "the header names the parent save")

	ScriptServer.move_reference(player, marker.current_space_form_id, marker.position, marker.rotation)
	check(saves.save("test_d") == ERR_BUSY and saves.report[0].contains("move"), "a save is refused while a move is queued: %s" % ", ".join(saves.report))
	ScriptServer.apply_pending_moves()

	for entry: Dictionary in backend.list():
		backend.delete(String(entry["save_id"]))
	check(backend.list().is_empty(), "deleted saves are gone")
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

## The first difference between two save states' sections, header aside
## (its saved_at differs), compared as JSON values; "" when they match.
func _sections_differ(a: Dictionary, b: Dictionary) -> String:
	var a_sections := a.duplicate()
	var b_sections := b.duplicate()
	a_sections.erase("header")
	b_sections.erase("header")
	return SaveCompare.first_difference(JSON.parse_string(JSON.stringify(a_sections)), JSON.parse_string(JSON.stringify(b_sections)))

## The files, relative to the folder, whose text differs between two saves.
func _changed_files(a: String, b: String) -> Array:
	var changed := []
	for file in _files(a):
		if FileAccess.get_file_as_string(a.path_join(file)) != FileAccess.get_file_as_string(b.path_join(file)):
			changed.append(file)
	changed.sort()
	return changed

func _files(folder: String, prefix: String = "") -> Array:
	var files := []
	for file in DirAccess.get_files_at(folder):
		files.append(prefix + file)
	for sub in DirAccess.get_directories_at(folder):
		files.append_array(_files(folder.path_join(sub), prefix + sub + "/"))
	return files

func _write_json(path: String, value: Variant) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(value, "\t", true))
	file.close()
