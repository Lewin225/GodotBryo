class_name ConsoleOverlay
extends CanvasLayer

## Drop-down console over the game, opened and closed with ` (the
## toggle_console action) and closed with Escape. It shows a ConsoleSession:
## lines typed here run through it, and its output scrolls above the input.
## While open the game is in menu mode as the console (ScriptServer
## MENU_CONSOLE), which frees the mouse, and a left click in the world picks
## the reference under the cursor as the target (`prid`). While open, a box
## outlines the target's meshes, drawn through walls (TargetBox).
##
## Keys in the input: Tab completes (the highlighted suggestion, else the
## first); Up/Down move through the suggestions while they show, else through
## history; Enter runs the line, or applies a highlighted suggestion;
## Hold-to-run: hold ` to open the console, type a command and let go of ` to
## run it and close the console again (it stays open if the command printed an
## error or warning, so you can read it). A tap of ` just opens it.
## Ctrl+L clears the output; Page Up/Down scroll it. A suggestion can also be
## clicked, and the wheel or a trackpad scroll over them moves the highlight
## as Up/Down do.
## VISIBLE_SUGGESTIONS show at a time; moving the highlight past either end
## scrolls through the rest. Ctrl+= / Ctrl+- (or Ctrl+wheel over the console)
## zoom the text, Ctrl+0 resets it; the zoom is kept in user://console.cfg.

const TOGGLE_ACTION := &"toggle_console"
## How far a click picks, in metres.
const PICK_DISTANCE := 500.0
## Output lines kept; older ones are dropped.
const OUTPUT_LIMIT := 2000
## Suggestions shown at once.
const VISIBLE_SUGGESTIONS := 12
## Most suggestions fetched, to scroll through.
const SUGGESTION_LIMIT := 200
## Trackpad scroll distance (InputEventPanGesture delta.y) per suggestion
## row. ScrollContainer scrolls a page per 8, so a row of a 12-row page is
## about 0.67.
const PAN_PER_ROW := 0.6
## Text zoom range and step, as a factor of the scene's font sizes.
const ZOOM_MIN := 0.6
const ZOOM_MAX := 2.5
const ZOOM_STEP := 0.1
const SETTINGS_PATH := "user://console.cfg"
const COLORS := {
	"input": "#61afef", "result": "#98c379", "info": "#abb2bf",
	"warning": "#e5c07b", "error": "#e06c75",
}

@onready var _panel: PanelContainer = $Panel
@onready var _target_label: RichTextLabel = $Panel/Margin/VBox/TargetRow/Target
@onready var _clear_target: Button = $Panel/Margin/VBox/TargetRow/ClearTarget
@onready var _target_box: MeshInstance3D = $TargetBox
@onready var _buttons: HFlowContainer = $Panel/Margin/VBox/Buttons
@onready var _output: RichTextLabel = $Panel/Margin/VBox/Output
@onready var _signature: RichTextLabel = $Panel/Margin/VBox/Signature
@onready var _line: LineEdit = $Panel/Margin/VBox/InputRow/Line
@onready var _suggestions: PanelContainer = $Suggestions
@onready var _suggestion_list: RichTextLabel = $Suggestions/Margin/List

var session: ConsoleSession
var _open := false
var _history_index := -1
var _draft := ""
## The last ConsoleCompleter.complete() result shown.
var _completion := {}
## The highlighted suggestion, or -1 for none.
var _selected := -1
## The first suggestion shown.
var _scroll := 0
## Trackpad scroll not yet turned into a whole row.
var _pan := 0.0
## The console was opened by pressing ` and ` has not been let go yet: letting
## go with something typed runs it.
var _key_held_open := false
## An error or warning was printed since _quick_run began.
var _quick_problem := false
## ConsoleSession.BUTTONS' buttons, in the same order.
var _button_nodes: Array[Button] = []
## The box TargetBox draws, in the target node's space.
var _box_aabb := AABB()
var _zoom := 1.0
## [Control, theme font size name, size at zoom 1] for every text in the console.
var _font_sizes: Array = []

func _ready() -> void:
	add_to_group(&"console")
	session = ConsoleSession.new(get_node_or_null("/root/ScriptServer"))
	session.output.connect(_on_output)
	session.clear_requested.connect(_output.clear)
	session.target_changed.connect(func(_reference: EsmReference) -> void: _update_target_label())
	_line.text_submitted.connect(_on_submitted)
	_line.text_changed.connect(_on_text_changed)
	_line.gui_input.connect(_on_line_gui_input)
	_suggestion_list.gui_input.connect(_on_suggestion_gui_input)
	_clear_target.pressed.connect(_on_clear_target)
	_build_buttons()
	_collect_font_sizes()
	_set_zoom(_load_zoom(), false)
	_target_box.mesh = ImmediateMesh.new()
	_panel.visible = false
	_suggestions.visible = false
	_update_target_label()
	_on_output({"kind": "info", "text": "type 'help' to list commands"})

func is_open() -> bool:
	return _open

func set_open(open: bool) -> void:
	if open == _open:
		return
	_open = open
	_panel.visible = open
	var server := session.script_server
	if open:
		if server != null:
			server.enter_menu(server.MENU_CONSOLE)
		_line.grab_focus()
		if not session.completer.is_index_ready() and session.completer.ensure_index():
			session.report_status()
	else:
		_key_held_open = false
		_line.release_focus()
		_hide_suggestions()
		if server != null:
			server.exit_menu(server.MENU_CONSOLE)

## Makes `reference` the target and opens the console (Script Engine tab).
func target_reference(reference: EsmReference) -> void:
	session.set_target(reference)
	_on_output({"kind": "info", "text": "target: " + session.describe_reference(reference)})
	set_open(true)

func _input(event: InputEvent) -> void:
	if event.is_action_pressed(TOGGLE_ACTION):
		var opening := not _open
		set_open(opening)
		_key_held_open = opening
		get_viewport().set_input_as_handled()
		return
	# Held down, the key repeats; those repeats would type ` into the input.
	if _open and event is InputEventKey and (event as InputEventKey).echo and event.is_action(TOGGLE_ACTION):
		get_viewport().set_input_as_handled()
		return
	if _open and _key_held_open and event.is_action_released(TOGGLE_ACTION):
		_key_held_open = false
		if _quick_run():
			get_viewport().set_input_as_handled()
		return
	if not _open:
		return
	if _zoom_input(event):
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"ui_cancel"):
		if _suggestions.visible:
			_hide_suggestions()
		else:
			set_open(false)
		get_viewport().set_input_as_handled()
	# Tab is ui_menu, which toggles the Debug Tools window in its own _input,
	# and LineEdit opens its context menu when a ui_menu key is released.
	# While typing here Tab completes instead, so both its press and its
	# release stop here.
	elif event is InputEventKey and (event as InputEventKey).keycode == KEY_TAB and _line.has_focus():
		if event.pressed:
			_tab_complete()
		get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return
	var button := event as InputEventMouseButton
	if button != null and button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
		_pick(button.position)
		get_viewport().set_input_as_handled()

## Sets the target to the reference whose node is under `screen_position`.
func _pick(screen_position: Vector2) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var from := camera.project_ray_origin(screen_position)
	var query := PhysicsRayQueryParameters3D.create(from, from + camera.project_ray_normal(screen_position) * PICK_DISTANCE)
	var server := session.script_server
	var player_body := server.player_node as CollisionObject3D if server != null else null
	if player_body != null:
		query.exclude = [player_body.get_rid()]
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		_on_output({"kind": "warning", "text": "pick: nothing under the cursor within %d m" % PICK_DISTANCE})
		_line.grab_focus()
		return
	var node := InteractRay.semantic_target(hit["collider"]) as EsmNode
	if node == null or node.reference == null:
		_on_output({"kind": "warning", "text": "pick: %s is not a reference's node" % (hit["collider"] as Node).name})
	else:
		session.set_target(node.reference)
		_on_output({"kind": "info", "text": "target: %s, %.1f m away" % [session.describe_reference(node.reference), from.distance_to(hit["position"])]})
	_line.grab_focus()

## The target row above the input: the target, and Clear while there is one.
func _update_target_label() -> void:
	_clear_target.visible = session.target != null
	if session.target == null:
		_target_label.text = "[color=#5c6370]target[/color] [color=#7f848e]none: click the world or prid Ref to set one[/color]"
	else:
		_target_label.text = "[color=#5c6370]target[/color] [b][color=#e5c07b]%s[/color][/b]" % _escape(session.describe_reference(session.target))

func _on_clear_target() -> void:
	session.set_target(null)
	_on_output({"kind": "info", "text": "target cleared"})
	_line.grab_focus()

## Runs what was typed while ` was held, then closes the console, unless it
## printed an error or warning. Returns whether anything was typed.
func _quick_run() -> bool:
	var text := _line.text.strip_edges()
	if text.is_empty():
		return false
	_quick_problem = false
	_on_submitted(text)
	if not _quick_problem:
		set_open(false)
	return true

func _on_output(entry: Dictionary) -> void:
	var kind := String(entry.get("kind", "info"))
	if kind == "error" or kind == "warning":
		_quick_problem = true
	var text := _escape(String(entry.get("text", "")))
	match kind:
		"input": text = "› " + text
		"warning": text = "! " + text
		"error": text = "✗ " + text
	_output.append_text("[color=%s]%s[/color]\n" % [COLORS.get(kind, COLORS["info"]), text])
	while _output.get_paragraph_count() > OUTPUT_LIMIT:
		_output.remove_paragraph(0)

static func _escape(text: String) -> String:
	return text.replace("[", "[lb]")

func _on_submitted(text: String) -> void:
	_hide_suggestions()
	_line.clear()
	_history_index = -1
	_draft = ""
	session.submit(text)

func _on_text_changed(_text: String) -> void:
	_history_index = -1
	_refresh_completion(false)

func _on_line_gui_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return
	var showing := _suggestions.visible and not (_completion.get("items", []) as Array).is_empty()
	match key.keycode:
		KEY_DOWN:
			if showing:
				_move_selection(1)
			else:
				_browse_history(1)
			_line.accept_event()
		KEY_UP:
			if showing:
				_move_selection(-1)
			else:
				_browse_history(-1)
			_line.accept_event()
		KEY_ENTER, KEY_KP_ENTER:
			if showing and _selected >= 0:
				_apply(_selected)
				_line.accept_event()
		KEY_L:
			if key.ctrl_pressed:
				_output.clear()
				_line.accept_event()
		KEY_PAGEUP, KEY_PAGEDOWN:
			var bar := _output.get_v_scroll_bar()
			bar.value += bar.page * (-1 if key.keycode == KEY_PAGEUP else 1)
			_line.accept_event()
		KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END:
			# The caret moves after this event; complete for where it lands.
			_refresh_completion.call_deferred(false)

func _browse_history(step: int) -> void:
	var history := session.history
	if history.is_empty():
		return
	if _history_index == -1:
		if step > 0:
			return
		_draft = _line.text
		_history_index = history.size() - 1
	else:
		_history_index += step
		if _history_index >= history.size():
			_history_index = -1
			_set_line(_draft)
			return
		_history_index = maxi(_history_index, 0)
	_set_line(history[_history_index])

func _set_line(text: String) -> void:
	_line.text = text
	_line.caret_column = text.length()
	_hide_suggestions()

## Shows suggestions for the word at the caret. A blank line shows none
## unless `force` (Tab on a blank line lists the commands).
func _refresh_completion(force: bool) -> void:
	if not _line.is_inside_tree():
		return
	if _line.text.strip_edges().is_empty() and not force:
		_hide_suggestions()
		return
	_completion = session.completer.complete(_line.text, _line.caret_column,
			{"target": session.target, "script_server": session.script_server}, SUGGESTION_LIMIT)
	_selected = -1
	_scroll = 0
	_pan = 0.0
	var signature := String(_completion.get("signature", ""))
	_signature.visible = not signature.is_empty()
	_signature.text = signature
	_render_suggestions()

func _render_suggestions() -> void:
	var items: Array = _completion.get("items", [])
	var word := _line.text.substr(int(_completion["start"]), int(_completion["end"]) - int(_completion["start"]))
	if items.is_empty() or (items.size() == 1 and String(items[0]["text"]).to_lower() == word.to_lower()):
		_suggestions.visible = false
		return
	# One line per shown suggestion, padded into two columns (the font is
	# monospace), so line i is suggestion _scroll + i for clicks and hover.
	# Widths come from every suggestion, so scrolling does not resize the list.
	_scroll = clampi(_scroll, 0, maxi(items.size() - VISIBLE_SUGGESTIONS, 0))
	var width := 0
	var detail_width := 0
	for item: Dictionary in items:
		width = maxi(width, String(item["text"]).length())
		detail_width = maxi(detail_width, String(item.get("detail", "")).length())
	var rows := PackedStringArray()
	for i in range(_scroll, mini(_scroll + VISIBLE_SUGGESTIONS, items.size())):
		var item: Dictionary = items[i]
		var text := " %s   " % String(item["text"]).rpad(width)
		# Padded too, so the highlight spans the whole row.
		var detail := "%s " % String(item.get("detail", "")).rpad(detail_width)
		if i == _selected:
			rows.append("[bgcolor=#2c313a][color=#61afef]%s[/color][color=#9da5b4]%s[/color][/bgcolor]" % [_escape(text), _escape(detail)])
		else:
			rows.append("[color=#d7dae0]%s[/color][color=#7f848e]%s[/color]" % [_escape(text), _escape(detail)])
	if items.size() > VISIBLE_SUGGESTIONS:
		rows.append("[color=#5c6370] %s %d–%d of %d%s  ·  scroll for more[/color]" % [
				"↑" if _scroll > 0 else " ", _scroll + 1, mini(_scroll + VISIBLE_SUGGESTIONS, items.size()), items.size(),
				"+" if _completion.get("more", false) else ""])
	_suggestion_list.text = "\n".join(rows)
	_suggestions.visible = true
	_suggestions.reset_size()
	_place_suggestions()

## One button per ConsoleSession.BUTTONS entry, under the input.
func _build_buttons() -> void:
	for i in ConsoleSession.BUTTONS.size():
		var button := Button.new()
		# Keeps the keyboard focus in the input, so typing and movement
		# suppression carry on after a click.
		button.focus_mode = Control.FOCUS_NONE
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.add_theme_font_size_override(&"font_size", 13)
		button.pressed.connect(_on_button_pressed.bind(i))
		_buttons.add_child(button)
		_button_nodes.append(button)
	_update_buttons()

## Labels, enabled state and tooltips follow the target (and its enabled state).
func _update_buttons() -> void:
	for i in _button_nodes.size():
		var spec: Dictionary = ConsoleSession.BUTTONS[i]
		var button := _button_nodes[i]
		var status := session.button_status(spec)
		button.text = session.button_label(spec)
		button.disabled = not status["enabled"]
		button.tooltip_text = String(spec.get("tip", "")) if status["enabled"] else "%s\n(%s)" % [spec.get("tip", ""), status["reason"]]

## Runs the button's command, or types it into the input to finish by hand.
func _on_button_pressed(index: int) -> void:
	var spec: Dictionary = ConsoleSession.BUTTONS[index]
	var command := session.button_command(spec)
	if spec.get("type_only", false):
		_set_line(command)
		var last_word := command.rfind(" ") + 1
		_line.select(last_word, command.length())
	else:
		session.submit(command, not spec.get("ignore_target", false))
	_line.grab_focus()

## Puts the suggestions under the input, at the word being completed. Run
## every frame they show: the input's rect is only right once the panel has
## laid out, which is after the frame it opens in.
func _place_suggestions() -> void:
	var font := _line.get_theme_font(&"font")
	var font_size := _line.get_theme_font_size(&"font_size")
	var offset := font.get_string_size(_line.text.left(int(_completion["start"])), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var rect := _line.get_global_rect()
	var x := minf(rect.position.x + offset, get_viewport().get_visible_rect().size.x - _suggestions.size.x - 8.0)
	_suggestions.position = Vector2(maxf(x, 0.0), rect.end.y + 4.0)

func _process(_delta: float) -> void:
	if _suggestions.visible:
		_place_suggestions()
	if _open:
		_update_buttons()
	_update_target_box()

## Outlines the target while the console is open: the box around its node's
## meshes, following the node. Hidden when the target is not physicalised or
## has no mesh yet. Bounds are recomputed each frame, so a visual that
## changes (a detail swap, a NIF arriving) needs no hook; an animated actor's
## box is its meshes' rest bounds.
func _update_target_box() -> void:
	var node := EsmNode.node_for(session.target) if _open and session.target != null else null
	var aabb := local_mesh_aabb(node) if node != null else AABB()
	_target_box.visible = aabb.has_volume()
	if not _target_box.visible:
		return
	_target_box.global_transform = node.global_transform
	if aabb != _box_aabb:
		_box_aabb = aabb
		_draw_box(aabb)

## The bounds of every visible mesh under `node`, in `node`'s space; empty
## when it has none.
static func local_mesh_aabb(node: Node3D) -> AABB:
	var to_local := node.global_transform.affine_inverse()
	var bounds := AABB()
	var first := true
	for mesh_instance: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
		if mesh_instance.mesh == null or not mesh_instance.is_visible_in_tree():
			continue
		var aabb := (to_local * mesh_instance.global_transform) * mesh_instance.get_aabb()
		bounds = aabb if first else bounds.merge(aabb)
		first = false
	return bounds

## The box's 12 edges as lines: AABB endpoints differ by one bit per axis.
func _draw_box(aabb: AABB) -> void:
	var mesh := _target_box.mesh as ImmediateMesh
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for corner in 8:
		for axis_bit in [1, 2, 4]:
			if corner & axis_bit == 0:
				mesh.surface_add_vertex(aabb.get_endpoint(corner))
				mesh.surface_add_vertex(aabb.get_endpoint(corner | axis_bit))
	mesh.surface_end()

## Hover highlights the suggestion under the mouse; a click applies it.
func _on_suggestion_gui_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	var button := event as InputEventMouseButton
	# A trackpad's two-finger scroll arrives on macOS as a pan gesture, not as
	# wheel buttons.
	var pan := event as InputEventPanGesture
	if pan != null:
		_pan += pan.delta.y
		# The tolerance keeps rounding (0.3 + 0.3 < 0.6) from losing a row.
		while absf(_pan) >= PAN_PER_ROW - 0.0001:
			var step := 1 if _pan > 0.0 else -1
			_move_selection(step)
			_pan -= step * PAN_PER_ROW
		_suggestion_list.accept_event()
		return
	if button != null and button.pressed and not button.ctrl_pressed \
			and (button.button_index == MOUSE_BUTTON_WHEEL_UP or button.button_index == MOUSE_BUTTON_WHEEL_DOWN):
		_move_selection(-1 if button.button_index == MOUSE_BUTTON_WHEEL_UP else 1)
		_suggestion_list.accept_event()
		return
	if motion == null and (button == null or not button.pressed or button.button_index != MOUSE_BUTTON_LEFT):
		return
	var row := _suggestion_row((event as InputEventMouse).position.y)
	if row < 0:
		return
	if button != null:
		_apply(row)
		_line.grab_focus()
		_suggestion_list.accept_event()
	elif row != _selected:
		_selected = row
		_render_suggestions()

## The suggestion on the list line at local `y`, or -1.
func _suggestion_row(y: float) -> int:
	var shown := mini((_completion.get("items", []) as Array).size() - _scroll, VISIBLE_SUGGESTIONS)
	for i in mini(_suggestion_list.get_line_count(), shown):
		var top := _suggestion_list.get_line_offset(i)
		if y >= top and y < top + _suggestion_list.get_line_height(i):
			return _scroll + i
	return -1

func _move_selection(step: int) -> void:
	var count := (_completion.get("items", []) as Array).size()
	if count == 0:
		return
	_selected = (count - 1 if step < 0 else 0) if _selected < 0 else wrapi(_selected + step, 0, count)
	# Keep the highlight in view.
	if _selected < _scroll:
		_scroll = _selected
	elif _selected >= _scroll + VISIBLE_SUGGESTIONS:
		_scroll = _selected - VISIBLE_SUGGESTIONS + 1
	_render_suggestions()

func _tab_complete() -> void:
	if not _suggestions.visible:
		_refresh_completion(true)
		if not _suggestions.visible:
			return
		var items: Array = _completion.get("items", [])
		if items.size() != 1:
			return
	_apply(maxi(_selected, 0))

## Replaces the word being completed with suggestion `index`, then shows
## suggestions for what follows (the next argument).
func _apply(index: int) -> void:
	var items: Array = _completion.get("items", [])
	if index < 0 or index >= items.size():
		return
	var item: Dictionary = items[index]
	var start := int(_completion["start"])
	var end := int(_completion["end"])
	var rest := _line.text.substr(end)
	var inserted := String(item["text"])
	if item.get("append_space", true) and not rest.begins_with(" "):
		inserted += " "
	_line.text = _line.text.left(start) + inserted + rest
	_line.caret_column = start + inserted.length()
	_refresh_completion(false)

func _hide_suggestions() -> void:
	_suggestions.visible = false
	_selected = -1
	if _signature != null:
		_signature.visible = false

# --- Zoom -----------------------------------------------------------------------

## Ctrl+= / Ctrl++ / Ctrl+- / Ctrl+0 (Cmd on macOS too), and Ctrl+wheel over
## the console. Returns whether `event` zoomed.
func _zoom_input(event: InputEvent) -> bool:
	var key := event as InputEventKey
	if key != null and key.pressed and (key.ctrl_pressed or key.meta_pressed):
		match key.keycode:
			KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
				_set_zoom(_zoom + ZOOM_STEP)
				return true
			KEY_MINUS, KEY_KP_SUBTRACT:
				_set_zoom(_zoom - ZOOM_STEP)
				return true
			KEY_0, KEY_KP_0:
				_set_zoom(1.0)
				return true
	var wheel := event as InputEventMouseButton
	if wheel != null and wheel.pressed and wheel.ctrl_pressed and _panel.get_global_rect().has_point(wheel.position):
		if wheel.button_index == MOUSE_BUTTON_WHEEL_UP:
			_set_zoom(_zoom + ZOOM_STEP)
			return true
		if wheel.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_set_zoom(_zoom - ZOOM_STEP)
			return true
	return false

## Records every console text's font size at zoom 1, from the scene.
func _collect_font_sizes() -> void:
	var labels: Array[Control] = [$Panel/Margin/VBox/Header/Title, $Panel/Margin/VBox/Header/Hint, $Panel/Margin/VBox/InputRow/Prompt, _line, _clear_target]
	labels.append_array(_button_nodes)
	var rich: Array[Control] = [_target_label, _output, _signature, _suggestion_list]
	for control in labels:
		_font_sizes.append([control, &"font_size", control.get_theme_font_size(&"font_size")])
	for control in rich:
		for size_name: StringName in [&"normal_font_size", &"bold_font_size"]:
			_font_sizes.append([control, size_name, control.get_theme_font_size(size_name)])

## Applies `zoom`, saving it when `save` and it changed.
func _set_zoom(zoom: float, save := true) -> void:
	zoom = clampf(snappedf(zoom, ZOOM_STEP), ZOOM_MIN, ZOOM_MAX)
	var changed := save and not is_equal_approx(zoom, _zoom)
	_zoom = zoom
	for entry: Array in _font_sizes:
		(entry[0] as Control).add_theme_font_size_override(entry[1], roundi(int(entry[2]) * zoom))
	if _suggestions.visible:
		_suggestions.reset_size()
	if changed:
		_save_zoom()

func get_zoom() -> float:
	return _zoom

func _load_zoom() -> float:
	var config := ConfigFile.new()
	return float(config.get_value("console", "zoom", 1.0)) if config.load(SETTINGS_PATH) == OK else 1.0

func _save_zoom() -> void:
	var config := ConfigFile.new()
	config.load(SETTINGS_PATH)
	config.set_value("console", "zoom", _zoom)
	config.save(SETTINGS_PATH)
