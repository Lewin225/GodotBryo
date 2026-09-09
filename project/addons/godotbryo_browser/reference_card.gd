@tool
extends PanelContainer

signal activated(card: Control)
signal context_requested(card: Control, screen_position: Vector2i)

var instance_id := ""
var reference_id := 0

func configure(reference_type: String, reference_id: int, base_id: int, base_name: String) -> void:
	self.reference_id = reference_id
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
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)
	var title := Label.new()
	title.text = "%s  authored:%08X" % [reference_type, reference_id]
	title.clip_text = true
	box.add_child(title)
	var metadata := Label.new()
	metadata.text = "Base: %s  0x%08X" % [base_name if not base_name.is_empty() else "Unknown", base_id]
	metadata.modulate = Color(0.65, 0.68, 0.73)
	box.add_child(metadata)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT and event.double_click:
			activated.emit(self)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			context_requested.emit(self, Vector2i(DisplayServer.mouse_get_position()))

func get_reference_id() -> int:
	return reference_id
