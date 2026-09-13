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
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.12, 0.13, 0.16, 1.0)
	panel_style.border_color = Color(0.34, 0.38, 0.46, 1.0)
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(3)
	panel_style.content_margin_left = 8.0
	panel_style.content_margin_right = 8.0
	panel_style.content_margin_top = 6.0
	panel_style.content_margin_bottom = 6.0
	add_theme_stylebox_override("panel", panel_style)
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
	metadata.modulate = Color(0.65, 0.68, 0.73)
	box.add_child(metadata)

func set_resource(value: EsmBase) -> void:
	resource = value

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
