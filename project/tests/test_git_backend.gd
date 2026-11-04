extends Node

## GitBackend against the git command, with save states made here rather
## than from a game: saves are commits under refs/saves/ in one repository
## per playthrough; each reads back as written; a save written after reading
## an earlier one has that save as its parent (a branch); list() names every
## save as `<playthrough>/<save_id>`; a save that changes one file of many
## adds little to the repository; delete removes the save. The repository is
## user://test_git_backend and is deleted after.

const ROOT := "user://test_git_backend"
const UNCHANGED_FILES := 200

var failures := 0
var backend: GitBackend


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	if not GitBackend.is_available():
		check(false, "git runs")
		_finish()
		return
	_remove_folder(ROOT)
	backend = GitBackend.new(ROOT)
	backend.playthrough_id = "first"

	var first := _state("first", 1)
	check(backend.write("one", first) == OK, "the first save is written: %s" % backend.last_error)
	var size_after_one := _repository_size("first")
	var second := _state("first", 2)
	check(backend.write("two", second) == OK, "the second save is written: %s" % backend.last_error)
	var growth := _repository_size("first") - size_after_one
	check(growth < 20000, "a save that changes one of %d files adds %d bytes" % [UNCHANGED_FILES, growth])
	check(_parent("first", "two") == _commit("first", "one"), "the second save's parent is the first")

	check(_same(backend.read("one"), first), "the first save reads back as written")
	var third := _state("first", 3)
	check(backend.write("three", third) == OK, "a save after reading the first is written")
	check(_parent("first", "three") == _commit("first", "one"), "it branches from the first save")
	check(_same(backend.read("first/two"), second), "a save named with its playthrough reads back")

	backend.playthrough_id = "second"
	check(backend.write("one", _state("second", 9)) == OK, "a save in another playthrough is written")
	check(int(backend.read("first/one")["quest_server"]["stage"]) == 1 and int(backend.read("second/one")["quest_server"]["stage"]) == 9,
			"playthroughs keep their saves apart")

	var ids: Array = backend.list().map(func(header: Dictionary) -> String: return header["save_id"])
	ids.sort()
	check(ids == ["first/one", "first/three", "first/two", "second/one"], "list() names every save (%s)" % ", ".join(ids))
	check(backend.has_save("first/three") and not backend.has_save("first/four"), "has_save() finds a save")
	check(backend.delete("first/three") == OK and not backend.has_save("first/three"), "delete() removes a save")
	check(backend.read("first/three").is_empty() and not backend.last_error.is_empty(), "a deleted save does not read")

	var spaced := _state("second", 4)
	check(backend.write("my save", spaced) == OK and _same(backend.read("second/my save"), spaced), "a save_id with a space works")
	_finish()


func _finish() -> void:
	_remove_folder(ROOT)
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(1 if failures > 0 else 0)


## A save state with a header, a small section that changes with `stage`, and
## UNCHANGED_FILES reference files that never change.
func _state(playthrough: String, stage: int) -> Dictionary:
	var references := {}
	var space_names := {}
	for index in UNCHANGED_FILES:
		var space := "FalloutNV.esm:%06X" % index
		space_names[space] = "Space%d" % index
		var id := "FalloutNV.esm:%06X" % (0x100000 + index)
		references[id] = {"current_space_form_id": space, "position": [index * 1.5, 2.0, 3.25], "note": "x".repeat(500)}
	return {
		"header": {"version": 1, "playthrough": playthrough, "space_names": space_names},
		"quest_server": {"stage": stage},
		"esm_server": {"bases": {}, "runtime": {}, "references": references},
	}


func _commit(playthrough: String, save_name: String) -> String:
	return backend._git(playthrough, ["rev-parse", backend._ref(save_name)]).text


func _parent(playthrough: String, save_name: String) -> String:
	return backend._git(playthrough, ["rev-parse", backend._ref(save_name) + "^"]).text


func _repository_size(playthrough: String) -> int:
	return _folder_size(ROOT.path_join(playthrough).path_join("repo.git"))


func _folder_size(folder: String) -> int:
	var size := 0
	for sub in DirAccess.get_directories_at(folder):
		size += _folder_size(folder.path_join(sub))
	for file in DirAccess.get_files_at(folder):
		size += FileAccess.get_size(folder.path_join(file))
	return size


func _remove_folder(folder: String) -> void:
	if not DirAccess.dir_exists_absolute(folder):
		return
	for sub in DirAccess.get_directories_at(folder):
		_remove_folder(folder.path_join(sub))
	for file in DirAccess.get_files_at(folder):
		DirAccess.remove_absolute(folder.path_join(file))
	DirAccess.remove_absolute(folder)


func _same(a: Variant, b: Variant) -> bool:
	var difference := SaveCompare.first_difference(a, b)
	if not difference.is_empty():
		print("        differs at ", difference)
	return difference.is_empty()
