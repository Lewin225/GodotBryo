extends Node

## Saves and loads the game. Builds a save state (a header and one section of
## plain values per owner) from the owners' save_state(), hands it to a
## backend, and on load checks a save state's header and applies its sections
## to the owners' load_state(). Owns the save state's format version and
## schema (README.md), the master check, when saving is refused, and which
## backend stores saves. Autoloaded as SaveServer.

const GameDataConfigScript := preload("res://game_data_config.gd")

## Emitted through a load as it goes: the stage, what it is working on by name,
## and a count when the stage has one (`total` 0 otherwise).
signal progress(stage: String, detail: String, done: int, total: int)

## Where each load writes its report: what it took, each stage's time and the
## report's lines.
const LOAD_REPORT_PATH := "user://saves/last_load.txt"
## Moved references built per frame while a save is applied.
const MOVED_PER_FRAME := 32

## The save state's format version. A save from a newer version is refused;
## an older one is migrated before it is applied.
const FORMAT_VERSION := 1

## Sections every save has, in the order they load: EsmServer first (dirty
## bases, runtime and saved references), then the servers whose state links
## to references.
const SERVER_SECTIONS := ["esm_server", "quest_server", "script_server", "dialogue_server"]

## Backends by name; `backend_name` picks the one in use.
var backends: Dictionary = {}
var backend_name := "json_folder"
## Sections the game adds (time, weather): section name -> owner with
## save_state() and load_state(state, report). Loaded after SERVER_SECTIONS.
var extra_sections: Dictionary = {}
## Checks the game adds that refuse a save: each returns the reason, or ""
## to allow it (a transition in progress).
var save_refusals: Array[Callable] = []
## What the last load or check did beyond applying the save: warnings and
## dropped entries, one line each.
var report: Array[String] = []


func _ready() -> void:
	# Runs while the game is paused (get_tree().paused): it holds no game
	# state, so it keeps loading; see Servers/readme.md, Pausing.
	process_mode = Node.PROCESS_MODE_ALWAYS
	register_backend("json_folder", JsonFolderBackend.new())


func register_backend(backend_title: String, backend: SaveBackend) -> void:
	backends[backend_title] = backend


func get_backend() -> SaveBackend:
	return backends.get(backend_name)


## Why a save cannot be made now, or "" when it can: a conversation, a queued
## move, or a refusal the game added.
func get_save_refusal() -> String:
	if DialogueServer.get_conversation_speaker() != null:
		return "a conversation is in progress"
	if ScriptServer.has_pending_moves():
		return "a move is waiting for its space to load"
	for refusal: Callable in save_refusals:
		var reason: String = refusal.call()
		if not reason.is_empty():
			return reason
	return ""


## Saves the game under `save_id`, with `parent` as the save it continues
## from. Returns the backend's error, or ERR_BUSY when saving is refused (the
## reason in `report`).
func save(save_id: String, parent: String = "") -> Error:
	report.clear()
	var refusal := get_save_refusal()
	if not refusal.is_empty():
		report.append("not saved: " + refusal)
		return ERR_BUSY
	var backend := get_backend()
	var result := backend.write(save_id, build_state(parent))
	if result != OK:
		report.append("not saved: " + backend.last_error)
	return result


## The game's save state: the header and every section.
func build_state(parent: String = "") -> Dictionary:
	var state := {
		"esm_server": EsmServer.save_state(),
		"quest_server": QuestServer.save_state(),
		"script_server": ScriptServer.save_state(),
		"dialogue_server": DialogueServer.save_state(),
	}
	for section: String in extra_sections:
		state[section] = extra_sections[section].save_state()
	state["header"] = _build_header(state, parent)
	return state


## The save state stored under `save_id`, checked: {} when it cannot be
## loaded, with the reason in `report`. Warnings (a changed master) are added
## to `report` and do not stop it.
func read_save(save_id: String) -> Dictionary:
	report.clear()
	var backend := get_backend()
	progress.emit("Reading save", save_id, 0, 0)
	var state := backend.read(save_id)
	if state.is_empty():
		report.append("not loaded: " + backend.last_error)
		return {}
	(state["header"] as Dictionary)["save_id"] = save_id
	var refusal := check_header(state.get("header", {}))
	if not refusal.is_empty():
		report.append("not loaded: " + refusal)
		return {}
	return state


## Why a save with `header` cannot be loaded, or "": a newer format version or
## a master that is not loaded. A loaded master whose size or modified time
## differs, or a different load order, adds a warning to `report`.
func check_header(header: Dictionary) -> String:
	var version := int(header.get("version", 0))
	if version > FORMAT_VERSION:
		return "made by a newer version (format %d, this reads %d)" % [version, FORMAT_VERSION]
	var current := _masters()
	var current_files: Array = current.map(func(master: Dictionary) -> String: return String(master["file"]))
	var saved_files := []
	for master: Dictionary in header.get("masters", []):
		var file := String(master.get("file", ""))
		saved_files.append(file)
		var index := current_files.find(file)
		if index == -1:
			return "needs %s, which is not loaded" % file
		var loaded: Dictionary = current[index]
		if int(master.get("size", 0)) != int(loaded["size"]) or int(master.get("modified", 0)) != int(loaded["modified"]):
			report.append("warning: %s has changed since the save was made" % file)
	if saved_files != current_files.slice(0, saved_files.size()):
		report.append("warning: the load order differs from the save's")
	return ""


## Applies a checked save state's sections to their owners, EsmServer first,
## after clearing EsmServer's game state, across frames: a section, or a batch
## of moved references, per frame, with `progress` emitted before each.
## The caller pauses the game around it (get_tree().paused), so nothing acts
## on a half-applied save; SaveServer runs while paused. A coroutine; await
## it. Seeding the simulation and placing the player are the
## game's (Plans/Saving/save_load.md, Loading). Entries an owner drops are
## added to `report`, and the load report is written to LOAD_REPORT_PATH.
func apply_state(state: Dictionary) -> void:
	var timings: Array[String] = []
	var started := Time.get_ticks_usec()
	progress.emit("Loading save", "EsmServer: bases, runtime and saved references", 0, 0)
	EsmServer.clear_game_state()
	EsmServer.load_state(state.get("esm_server", {}), report, false)
	timings.append(_timing("esm_server", started))
	await get_tree().process_frame
	started = Time.get_ticks_usec()
	var moved := EsmServer.get_saved_moved_ids()
	for i in moved.size():
		if i % MOVED_PER_FRAME == 0:
			progress.emit("Moved references", moved[i], i, moved.size())
			await get_tree().process_frame
		EsmServer.get_reference(StringName(moved[i]))
	timings.append(_timing("%d moved references" % moved.size(), started))
	var owners := {"quest_server": QuestServer, "script_server": ScriptServer, "dialogue_server": DialogueServer}
	owners.merge(extra_sections)
	for section: String in owners:
		if not state.has(section):
			continue
		progress.emit("Loading save", section, 0, 0)
		await get_tree().process_frame
		started = Time.get_ticks_usec()
		owners[section].load_state(state[section], report)
		timings.append(_timing(section, started))
	_write_load_report(state, timings)


func _timing(stage: String, started_usec: int) -> String:
	return "%s: %.1f ms" % [stage, (Time.get_ticks_usec() - started_usec) / 1000.0]


## Writes what the last load did to LOAD_REPORT_PATH, for bug reports.
func _write_load_report(state: Dictionary, timings: Array[String]) -> void:
	var header: Dictionary = state.get("header", {})
	var esm: Dictionary = state.get("esm_server", {})
	var lines: Array[String] = [
		"Loaded %s (saved %s, format %s)" % [header.get("save_id", "?"), header.get("saved_at", "?"), header.get("version", "?")],
		"Player in %s" % header.get("player_cell", "?"),
		"References %d, runtime %d, bases %d, quest states %d" % [
			(esm.get("references", {}) as Dictionary).size(),
			((esm.get("runtime", {}) as Dictionary).get("references", {}) as Dictionary).size(),
			(esm.get("bases", {}) as Dictionary).size(),
			((state.get("quest_server", {}) as Dictionary).get("states", {}) as Dictionary).size()],
		"",
		"Times:",
	]
	lines.append_array(timings)
	lines.append("")
	lines.append("Report:" if not report.is_empty() else "Report: nothing dropped, no warnings")
	lines.append_array(report)
	DirAccess.make_dir_recursive_absolute(LOAD_REPORT_PATH.get_base_dir())
	var file := FileAccess.open(LOAD_REPORT_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string("\n".join(lines) + "\n")
	file.close()


## The header: format version, masters, where the player is, the editor ID of
## every space a saved reference is in (for the backend's file names), the
## real time saved and the parent save.
func _build_header(state: Dictionary, parent: String) -> Dictionary:
	var player := EsmServer.get_player_reference()
	var space_names := {}
	for entry: Dictionary in (state["esm_server"]["references"] as Dictionary).values():
		var space: Variant = entry.get("current_space_form_id")
		if space != null and not space_names.has(space):
			space_names[space] = _editor_id(EsmServer.form_id_for_instance_id(String(space)))
	var header := {
		"version": FORMAT_VERSION,
		"masters": _masters(),
		"player_space": String(EsmServer.instance_id_for_form_id(player.current_space_form_id)) if player.current_space_form_id != 0 else null,
		"player_position": [player.position.x, player.position.y, player.position.z],
		"player_cell": _editor_id(player.current_cell_form_id),
		"space_names": space_names,
		"saved_at": Time.get_datetime_string_from_system(true),
		"parent": parent if not parent.is_empty() else null,
	}
	return header


## Every loaded master in load order, with its size and modified time.
func _masters() -> Array:
	var data_dir := String(GameDataConfigScript.resolve().get("data_dir", ""))
	var masters := []
	for file in EsmServer.load_order:
		var path := data_dir.path_join(file)
		var size := 0
		var handle := FileAccess.open(path, FileAccess.READ)
		if handle != null:
			size = handle.get_length()
			handle.close()
		masters.append({"file": file, "size": size, "modified": FileAccess.get_modified_time(path)})
	return masters


func _editor_id(form_id: int) -> String:
	var record := EsmServer.get_base(form_id) if form_id != 0 else null
	return record.editor_id if record != null else ""
