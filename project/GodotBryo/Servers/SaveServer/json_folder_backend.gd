class_name JsonFolderBackend
extends SaveBackend

## Stores each save as a folder of indented, key-sorted JSON files, one per
## section, so two saves diff cleanly and a section is found and edited by
## hand (README.md, Format). EsmServer's section is split: its bases and
## runtime references in their own files, and its references by the space
## they are in, named from the header's `space_names`.
##
##   <root>/<save_id>/header.json
##   <root>/<save_id>/<section>.json
##   <root>/<save_id>/esm_server/bases.json, runtime.json
##   <root>/<save_id>/esm_server/references/<space>.json
##
## A save is written to `<save_id>.writing` and renamed into place, so a
## failed write leaves the save that was there.

const WRITING_SUFFIX := ".writing"
const REPLACED_SUFFIX := ".replaced"

## The folder that holds the saves.
var root := "user://saves"


func _init(saves_root: String = "user://saves") -> void:
	root = saves_root
	title = "Full (a folder per save)"


func write(save_id: String, state: Dictionary) -> Error:
	last_error = ""
	var folder := _save_folder(save_id)
	var writing := folder + WRITING_SUFFIX
	_remove_folder(writing)
	var made := DirAccess.make_dir_recursive_absolute(writing)
	if made != OK:
		return _fail(made, "cannot make %s" % writing)
	for section: String in state:
		var result := OK
		if section == "esm_server":
			result = _write_esm_server(writing, state[section], state.get("header", {}))
		else:
			result = _write_json(writing.path_join(section + ".json"), state[section])
		if result != OK:
			_remove_folder(writing)
			return result
	var replaced := folder + REPLACED_SUFFIX
	_remove_folder(replaced)
	if DirAccess.dir_exists_absolute(folder):
		var moved_aside := DirAccess.rename_absolute(folder, replaced)
		if moved_aside != OK:
			_remove_folder(writing)
			return _fail(moved_aside, "cannot move the old %s aside" % folder)
	var renamed := DirAccess.rename_absolute(writing, folder)
	if renamed != OK:
		DirAccess.rename_absolute(replaced, folder)
		return _fail(renamed, "cannot move %s into place" % writing)
	_remove_folder(replaced)
	return OK


func read(save_id: String) -> Dictionary:
	last_error = ""
	var folder := _save_folder(save_id)
	if not DirAccess.dir_exists_absolute(folder):
		_fail(ERR_FILE_NOT_FOUND, "no save %s" % save_id)
		return {}
	var state := {}
	for file in DirAccess.get_files_at(folder):
		if file.get_extension() != "json":
			continue
		var value: Variant = _read_json(folder.path_join(file))
		if value == null:
			return {}
		state[file.get_basename()] = value
	if DirAccess.dir_exists_absolute(folder.path_join("esm_server")):
		var esm_server := _read_esm_server(folder.path_join("esm_server"))
		if esm_server.is_empty():
			return {}
		state["esm_server"] = esm_server
	if not state.has("header"):
		_fail(ERR_FILE_CORRUPT, "%s has no header.json" % save_id)
		return {}
	return state


func list() -> Array[Dictionary]:
	var saves: Array[Dictionary] = []
	if not DirAccess.dir_exists_absolute(root):
		return saves
	for folder in DirAccess.get_directories_at(root):
		if folder.ends_with(WRITING_SUFFIX) or folder.ends_with(REPLACED_SUFFIX):
			continue
		var header: Variant = _read_json(root.path_join(folder).path_join("header.json"))
		if header is Dictionary:
			var entry: Dictionary = header.duplicate()
			entry["save_id"] = folder
			saves.append(entry)
	return saves


func delete(save_id: String) -> Error:
	last_error = ""
	var folder := _save_folder(save_id)
	if not DirAccess.dir_exists_absolute(folder):
		return _fail(ERR_FILE_NOT_FOUND, "no save %s" % save_id)
	return _remove_folder(folder)


## The folder a save lives in; `save_id` is made a valid file name.
func _save_folder(save_id: String) -> String:
	return root.path_join(save_id.validate_filename())


## EsmServer's section as files: bases, runtime references, and references
## grouped by the space they are in.
func _write_esm_server(folder: String, section: Dictionary, header: Dictionary) -> Error:
	var esm_folder := folder.path_join("esm_server")
	var references_folder := esm_folder.path_join("references")
	DirAccess.make_dir_recursive_absolute(references_folder)
	var result := _write_json(esm_folder.path_join("bases.json"), section.get("bases", {}))
	if result != OK:
		return result
	result = _write_json(esm_folder.path_join("runtime.json"), section.get("runtime", {}))
	if result != OK:
		return result
	var space_names: Dictionary = header.get("space_names", {})
	var by_space := {}
	var references: Dictionary = section.get("references", {})
	for id: String in references:
		var space: Variant = (references[id] as Dictionary).get("current_space_form_id")
		var file := _space_file_name(space, space_names)
		if not by_space.has(file):
			by_space[file] = {}
		by_space[file][id] = references[id]
	for file: String in by_space:
		result = _write_json(references_folder.path_join(file), by_space[file])
		if result != OK:
			return result
	return OK


func _read_esm_server(folder: String) -> Dictionary:
	var section := {}
	for part in ["bases", "runtime"]:
		var value: Variant = _read_json(folder.path_join(part + ".json"))
		if value == null:
			return {}
		section[part] = value
	var references := {}
	var references_folder := folder.path_join("references")
	for file in DirAccess.get_files_at(references_folder):
		var value: Variant = _read_json(references_folder.path_join(file))
		if not value is Dictionary:
			return {}
		references.merge(value)
	section["references"] = references
	return section


## `<space editor ID>.json`, or the space's `<file>:<local id>` made a file
## name when the header names no editor ID; `unplaced.json` for no space.
static func _space_file_name(space: Variant, space_names: Dictionary) -> String:
	if space == null:
		return "unplaced.json"
	var name := String(space_names.get(space, ""))
	if name.is_empty():
		name = String(space)
	return name.validate_filename() + ".json"


func _write_json(path: String, value: Variant) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _fail(FileAccess.get_open_error(), "cannot write %s" % path)
	file.store_string(JSON.stringify(value, "\t", true))
	file.close()
	return OK


## The parsed contents of `path`, or null with last_error set.
func _read_json(path: String) -> Variant:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty() and FileAccess.get_open_error() != OK:
		_fail(FileAccess.get_open_error(), "cannot read %s" % path)
		return null
	var json := JSON.new()
	if json.parse(text) != OK:
		_fail(ERR_PARSE_ERROR, "%s line %d: %s" % [path, json.get_error_line(), json.get_error_message()])
		return null
	return json.data


func _remove_folder(folder: String) -> Error:
	if not DirAccess.dir_exists_absolute(folder):
		return OK
	for sub in DirAccess.get_directories_at(folder):
		var removed := _remove_folder(folder.path_join(sub))
		if removed != OK:
			return removed
	for file in DirAccess.get_files_at(folder):
		DirAccess.remove_absolute(folder.path_join(file))
	return DirAccess.remove_absolute(folder)


func _fail(error: Error, message: String) -> Error:
	last_error = message
	return error
