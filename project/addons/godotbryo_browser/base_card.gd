@tool
extends PanelContainer

signal activated(card: Control)
signal context_requested(card: Control, screen_position: Vector2i)

var row: Dictionary
var resource: EsmBase

func configure(record: Dictionary) -> void:
	row = record
	# The browser is a dense catalogue: keep each two-line entry rectangular
	# and uniform instead of allowing the GridContainer to stretch cards.
	custom_minimum_size = Vector2(240, 68)
	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	# Deliberately inherit PanelContainer's active editor theme rather than
	# freezing dark-theme colors into every card. This keeps both the panel and
	# labels legible when the editor switches to a light theme.
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)
	var title := Label.new()
	title.text = String(record.get("display_name", ""))
	title.clip_text = true
	title.max_lines_visible = 1
	box.add_child(title)
	var metadata := Label.new()
	metadata.text = "%s  0x%08X" % [String(record.get("record_type", "")), int(record.get("form_id", 0))]
	box.add_child(metadata)

func set_resource(value: EsmBase) -> void:
	resource = value

func _draw() -> void:
	draw_rect(Rect2(Vector2(0.5, 0.5), size - Vector2.ONE), _editor_accent_color(), false, 1.0, true)

func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		queue_redraw()

func _editor_accent_color() -> Color:
	var editor_theme := EditorInterface.get_editor_theme()
	if editor_theme != null and editor_theme.has_color("accent_color", "Editor"):
		return editor_theme.get_color("accent_color", "Editor")
	return get_theme_color("font_hover_color", "Button")

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT and event.double_click:
			activated.emit(self)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			context_requested.emit(self, Vector2i(DisplayServer.mouse_get_position()))

func _get_drag_data(_at_position: Vector2) -> Variant:
	if resource == null:
		var server = Engine.get_main_loop().root.get_node_or_null("EsmServer")
		resource = server.get_base(int(row.get("form_id", 0))) if server != null else null
	if resource == null:
		return null
	var preview := Label.new()
	preview.text = String(row.get("display_name", ""))
	set_drag_preview(preview)
	return {"type": "resource", "resource": resource}
