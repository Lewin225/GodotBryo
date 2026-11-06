class_name IssueReporter
extends CanvasLayer

## F10 writes an issue report to IssueReports/<date_time>/ at the repository
## root: screenshot.png (the frame as it was), report.txt (where the player is,
## the commit, frame rate, and the actors near the player) and godot.log (this
## run's log so far). A note box then opens; Enter adds the note to
## report.txt, Escape closes it without one. While it is open the game is in
## menu mode as the console, which frees the mouse.

const REPORTS_FOLDER := "IssueReports"
## Actors within this many metres of the player are listed.
const NEAR_METRES := 30.0

var _note_panel: PanelContainer
var _note: LineEdit
var _report_path := ""


func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_note_panel()


func _build_note_panel() -> void:
	_note_panel = PanelContainer.new()
	_note_panel.visible = false
	_note_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_note_panel.position.y = 40.0
	_note_panel.custom_minimum_size = Vector2(640, 0)
	add_child(_note_panel)
	var box := VBoxContainer.new()
	_note_panel.add_child(box)
	var title := Label.new()
	title.text = "Issue saved. Add a note (Enter saves it, Escape skips):"
	box.add_child(title)
	_note = LineEdit.new()
	_note.text_submitted.connect(_on_note_submitted)
	box.add_child(_note)


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_F10 and not _note_panel.visible:
		get_viewport().set_input_as_handled()
		_capture()
	elif key.keycode == KEY_ESCAPE and _note_panel.visible:
		get_viewport().set_input_as_handled()
		_close_note()


func _capture() -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var folder := _new_report_folder()
	if folder.is_empty():
		return
	image.save_png(folder.path_join("screenshot.png"))
	_report_path = folder.path_join("report.txt")
	var file := FileAccess.open(_report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(_describe())
		file.close()
	_copy_log(folder)
	print("IssueReporter: wrote ", folder)
	_open_note()


## Makes IssueReports/<date_time>/ beside the project folder; empty on failure.
func _new_report_folder() -> String:
	var root := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var folder := root.path_join(REPORTS_FOLDER).path_join(stamp)
	var error := DirAccess.make_dir_recursive_absolute(folder)
	if error != OK:
		push_error("IssueReporter: could not create %s (%s)" % [folder, error_string(error)])
		return ""
	return folder


func _copy_log(folder: String) -> void:
	var log_path := ProjectSettings.globalize_path(String(ProjectSettings.get_setting("debug/file_logging/log_path", "user://logs/godot.log")))
	if FileAccess.file_exists(log_path):
		DirAccess.copy_absolute(log_path, folder.path_join("godot.log"))


func _describe() -> String:
	var lines := PackedStringArray()
	lines.append("time: %s" % Time.get_datetime_string_from_system())
	lines.append("commit: %s" % _commit())
	lines.append("fps: %d" % Engine.get_frames_per_second())
	var player := ScriptServer.player_reference as ActorReference
	if player == null:
		lines.append("player: none")
		return "\n".join(lines) + "\n"
	lines.append("player: %s" % player.instance_id)
	lines.append("space: %08X" % player.current_space_form_id)
	var cell := player.current_cell_form_id
	lines.append("cell: %s %08X%s" % [EsmServer.reader.get_cell_editor_id(cell), cell, _grid_text(cell)])
	lines.append("position: %s" % player.position)
	lines.append("rotation: %s" % player.rotation)
	lines.append("physicalised actors: %d" % get_tree().root.find_children("*", "NpcController", true, false).size())
	lines.append("")
	lines.append("actors within %d m:" % NEAR_METRES)
	if NpcSimulationServer.is_seeded:
		for actor in NpcSimulationServer.get_actors_in_range(player.current_space_form_id, player.position, NEAR_METRES):
			if actor != player:
				lines.append("  " + _actor_line(actor))
	return "\n".join(lines) + "\n"


func _grid_text(cell_form_id: int) -> String:
	var grid: Dictionary = EsmServer.reader.get_exterior_cell_grid(cell_form_id)
	if grid.is_empty():
		return ""
	return " (%d, %d)" % [int(grid["x"]), int(grid["y"])]


func _actor_line(actor: ActorReference) -> String:
	var base_name := actor.base.editor_id if actor.base != null else "?"
	var mode := "leased" if actor.simulation_mode == ActorReference.SimulationMode.PHYSICAL_LEASED else "low level"
	var package := actor.active_package.editor_id if actor.active_package != null else "none"
	var parts := PackedStringArray([base_name, actor.instance_id, mode, "package " + package, "at %s" % actor.position])
	if actor.is_disabled():
		parts.append("disabled")
	if actor.leveled_template != null:
		parts.append("leveled %s" % actor.leveled_template.editor_id)
	return "  ".join(parts)


func _commit() -> String:
	var output: Array = []
	var root := ProjectSettings.globalize_path("res://")
	if OS.execute("git", ["-C", root, "rev-parse", "--short", "HEAD"], output) != 0 or output.is_empty():
		return "unknown"
	return String(output[0]).strip_edges()


func _open_note() -> void:
	_note.text = ""
	_note_panel.visible = true
	_note.grab_focus()
	ScriptServer.enter_menu(ScriptServer.MENU_CONSOLE)


func _on_note_submitted(text: String) -> void:
	if not text.strip_edges().is_empty():
		var file := FileAccess.open(_report_path, FileAccess.READ_WRITE)
		if file != null:
			file.seek_end()
			file.store_string("\nnote: %s\n" % text)
			file.close()
	_close_note()


func _close_note() -> void:
	_note_panel.visible = false
	_note.release_focus()
	ScriptServer.exit_menu(ScriptServer.MENU_CONSOLE)
