class_name IssueReporter
extends CanvasLayer

## F10 captures an issue report: the frame as it was, and the report text
## (where the player is, the commit, frame rate, the console's target
## reference and the physicalised actors). A movable window shows both and
## takes a note. Nothing is written until Save report, which writes
## user://IssueReports/<date_time> - <commit> - <note's start>/: screenshot.png,
## report.txt (with the note) and godot.log (this run's log so far). Cancel,
## Escape or closing the window before saving discards the report. Open
## reports folder opens user://IssueReports at any time. Reports are never
## sent anywhere. While it is open the game is in menu mode as the console, which
## frees the mouse.

const REPORTS_FOLDER := "user://IssueReports"
const SCREENSHOT_FILE := "screenshot.png"
const REPORT_FILE := "report.txt"
const LOG_FILE := "godot.log"
## The report window's size when it opens, in pixels.
const DIALOG_SIZE := Vector2i(900, 640)
## Characters of the note a report's folder name takes.
const FOLDER_NOTE_LENGTH := 75
## Between the parts of a report's folder name.
const FOLDER_SEPARATOR := " - "
## Width of the dialog's screenshot preview, in pixels.
const PREVIEW_WIDTH := 360.0

var _dialog: Window
var _title: Label
var _intro: Label
var _preview: TextureRect
var _report_text: TextEdit
var _files_label: Label
var _note: TextEdit
var _unsaved_buttons: HBoxContainer
var _saved_buttons: HBoxContainer
## The captured report, held until it is saved or discarded.
var _screenshot: Image = null
var _report := ""
var _commit_hash := ""
## The saved report's folder; empty until Save report.
var _folder := ""


func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_dialog()


func _build_dialog() -> void:
	_dialog = Window.new()
	_dialog.title = "Problem report"
	_dialog.visible = false
	_dialog.size = DIALOG_SIZE
	_dialog.min_size = DIALOG_SIZE / 2
	_dialog.wrap_controls = false
	_dialog.close_requested.connect(_close_dialog)
	_dialog.window_input.connect(_on_dialog_input)
	add_child(_dialog)
	var background := Panel.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.13, 0.13, 0.14)
	background.add_theme_stylebox_override("panel", style)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dialog.add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 12)
	_dialog.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 20)
	box.add_child(_title)
	_intro = Label.new()
	_intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_intro)

	var captured := HBoxContainer.new()
	captured.add_theme_constant_override("separation", 8)
	captured.size_flags_vertical = Control.SIZE_EXPAND_FILL
	captured.size_flags_stretch_ratio = 2.0
	box.add_child(captured)
	_preview = TextureRect.new()
	_preview.custom_minimum_size = Vector2(PREVIEW_WIDTH, PREVIEW_WIDTH * 9.0 / 16.0)
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	captured.add_child(_preview)
	_report_text = TextEdit.new()
	_report_text.editable = false
	_report_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_report_text.add_theme_color_override("font_readonly_color", _report_text.get_theme_color("font_color"))
	_report_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_report_text.custom_minimum_size = Vector2(0, PREVIEW_WIDTH * 9.0 / 16.0)
	captured.add_child(_report_text)

	_files_label = Label.new()
	_files_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_files_label)

	var note_caption := Label.new()
	note_caption.text = "What went wrong? (optional)"
	box.add_child(note_caption)
	_note = TextEdit.new()
	_note.custom_minimum_size = Vector2(0, 90)
	_note.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_note.placeholder_text = "What you were doing, what you expected, and what happened instead."
	_note.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	box.add_child(_note)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 8)
	box.add_child(bottom)
	_add_button(bottom, "Open reports folder", _open_reports_folder)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(spacer)
	_unsaved_buttons = _button_row(bottom)
	_add_button(_unsaved_buttons, "Cancel", _close_dialog)
	_add_button(_unsaved_buttons, "Save report", _save_report)
	_saved_buttons = _button_row(bottom)
	_add_button(_saved_buttons, "Close", _close_dialog)
	var privacy := Label.new()
	privacy.text = "Reports are not sent anywhere. To share one, attach its files to a GitHub issue or post them on Discord."
	privacy.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	privacy.add_theme_color_override("font_color", Color(0.7, 0.7, 0.72))
	box.add_child(privacy)


func _button_row(parent: HBoxContainer) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	return row


func _add_button(row: HBoxContainer, text: String, action: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.pressed.connect(action)
	row.add_child(button)


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_F10 and not _dialog.visible:
		get_viewport().set_input_as_handled()
		_capture()


## Escape in the report window closes it: before saving, it discards the
## report.
func _on_dialog_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_ESCAPE:
		_dialog.set_input_as_handled()
		_close_dialog()


## Captures the frame and the report text, and shows them; writes nothing.
func _capture() -> void:
	await RenderingServer.frame_post_draw
	_screenshot = get_viewport().get_texture().get_image()
	_commit_hash = _commit()
	_report = _describe()
	_open_dialog()


## Writes the captured report and the note, if any, to a new folder, then
## shows the folder. Stays unsaved when the folder cannot be made.
func _save_report() -> void:
	var note := _note.text.strip_edges()
	var folder := _new_report_folder(note)
	if folder.is_empty():
		return
	_screenshot.save_png(folder.path_join(SCREENSHOT_FILE))
	var text := _report
	if not note.is_empty():
		text += "\nnote: %s\n" % note
	var file := FileAccess.open(folder.path_join(REPORT_FILE), FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()
	_copy_log(folder)
	print("IssueReporter: wrote ", folder)
	_folder = folder
	_show_saved()


## Makes user://IssueReports/<folder_name()>/ and returns its absolute path;
## empty on failure.
func _new_report_folder(note: String) -> String:
	var folder := ProjectSettings.globalize_path(REPORTS_FOLDER.path_join(folder_name(Time.get_datetime_string_from_system(), _commit_hash, note)))
	var error := DirAccess.make_dir_recursive_absolute(folder)
	if error != OK:
		push_error("IssueReporter: could not create %s (%s)" % [folder, error_string(error)])
		return ""
	return folder


## A report's folder name: the date and time, the commit and the note's first
## FOLDER_NOTE_LENGTH characters, joined by FOLDER_SEPARATOR. Characters a
## file name cannot hold and line breaks become spaces; an empty note is left
## out.
static func folder_name(datetime: String, commit: String, note: String) -> String:
	var parts := PackedStringArray([datetime.replace(":", "-").replace("T", "_"), commit])
	var cleaned := note
	for character in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\n", "\r", "\t"]:
		cleaned = cleaned.replace(character, " ")
	while cleaned.contains("  "):
		cleaned = cleaned.replace("  ", " ")
	cleaned = cleaned.strip_edges().left(FOLDER_NOTE_LENGTH).strip_edges().rstrip(".")
	if not cleaned.is_empty():
		parts.append(cleaned)
	return FOLDER_SEPARATOR.join(parts)


func _copy_log(folder: String) -> void:
	var log_path := _log_path()
	if FileAccess.file_exists(log_path):
		DirAccess.copy_absolute(log_path, folder.path_join(LOG_FILE))


func _log_path() -> String:
	return ProjectSettings.globalize_path(String(ProjectSettings.get_setting("debug/file_logging/log_path", "user://logs/godot.log")))


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
	lines.append("")
	lines.append_array(_target_lines())
	lines.append("")
	var controllers := get_tree().root.find_children("*", "NpcController", true, false)
	lines.append("physicalised actors: %d" % controllers.size())
	for controller: NpcController in controllers:
		if controller.actor_reference != null:
			lines.append("  " + _actor_line(controller.actor_reference))
	return "\n".join(lines) + "\n"


## The console's target reference (prid): what it is, where, its state and
## its script's variables. The console is the first ConsoleOverlay in the
## tree; with none, the target is none.
func _target_lines() -> PackedStringArray:
	var lines := PackedStringArray()
	var session := _console_session()
	var target: EsmReference = session.target if session != null else null
	if target == null:
		lines.append("console target: none")
		return lines
	lines.append("console target: %s (%s)" % [session.describe_reference(target), target.instance_id])
	var base := target.base
	if base != null:
		lines.append("  base: %s %s %08X" % [base.record_type, base.editor_id, base.form_id])
	var cell := target.current_cell_form_id
	lines.append("  space: %08X  cell: %s %08X%s" % [target.current_space_form_id, EsmServer.reader.get_cell_editor_id(cell), cell, _grid_text(cell)])
	lines.append("  position: %s  rotation: %s" % [target.position, target.rotation])
	lines.append("  disabled: %s  destroyed: %s  loaded node: %s" % [target.is_disabled(), target.destroyed, EsmNode.node_for(target) != null])
	if target is ActorReference:
		lines.append("  actor: " + _actor_line(target as ActorReference))
	if target.script_instance != null:
		for name in target.script_instance.locals:
			lines.append("  local %s = %s" % [name, target.script_instance.locals[name]])
	return lines


func _console_session() -> ConsoleSession:
	var consoles := get_tree().root.find_children("*", "ConsoleOverlay", true, false)
	if consoles.is_empty():
		return null
	return (consoles[0] as ConsoleOverlay).session


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


## Shows the captured report, unsaved: the note can be edited and the files
## are those Save report will write.
func _open_dialog() -> void:
	_folder = ""
	_title.text = "Problem report"
	_intro.text = "This is what the report will save. Describe what went wrong below, then press Save report. Cancel discards it."
	_preview.texture = ImageTexture.create_from_image(_screenshot)
	_report_text.text = _report
	_files_label.text = "Will save: %s" % ", ".join(_file_descriptions())
	_note.text = ""
	_note.editable = true
	_unsaved_buttons.visible = true
	_saved_buttons.visible = false
	_dialog.popup_centered(DIALOG_SIZE)
	_note.grab_focus()
	ScriptServer.enter_menu(ScriptServer.MENU_CONSOLE)


## Shows the saved report's folder in place of the save controls.
func _show_saved() -> void:
	_title.text = "Problem report saved"
	_intro.text = "Find it in the reports folder, and attach its files to your issue."
	_files_label.text = "Saved to \"%s\": %s" % [_folder.get_file(), ", ".join(_file_descriptions())]
	_note.editable = false
	_unsaved_buttons.visible = false
	_saved_buttons.visible = true


## The report's files, each with what it holds: those in the saved folder, or
## before saving those Save report will write (godot.log when this run has a
## log).
func _file_descriptions() -> PackedStringArray:
	var descriptions := PackedStringArray()
	var files := [
		[SCREENSHOT_FILE, "the screenshot above"],
		[REPORT_FILE, "the details above, and your note"],
		[LOG_FILE, "the game's log for this session"],
	]
	for entry in files:
		if _folder.is_empty():
			if entry[0] == LOG_FILE and not FileAccess.file_exists(_log_path()):
				continue
		elif not FileAccess.file_exists(_folder.path_join(entry[0])):
			continue
		descriptions.append("%s (%s)" % [entry[0], entry[1]])
	return descriptions


## Opens user://IssueReports in the file manager, making it first.
func _open_reports_folder() -> void:
	var folder := ProjectSettings.globalize_path(REPORTS_FOLDER)
	DirAccess.make_dir_recursive_absolute(folder)
	OS.shell_open(folder)


## Hides the window and drops the captured report; an unsaved report is
## discarded.
func _close_dialog() -> void:
	_dialog.hide()
	_note.release_focus()
	_preview.texture = null
	_screenshot = null
	_report = ""
	_commit_hash = ""
	_folder = ""
	ScriptServer.exit_menu(ScriptServer.MENU_CONSOLE)
