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
	# Use the editor's PanelContainer/Label theme colors so reference cards
	# remain readable in both dark and light editor themes.
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)
	var title := Label.new()
	title.text = "%s  authored:%08X" % [reference_type, reference_id]
	title.clip_text = true
	box.add_child(title)
	var metadata := Label.new()
	metadata.text = "Base: %s  0x%08X" % [base_name if not base_name.is_empty() else "Unknown", base_id]
	box.add_child(metadata)

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

func get_reference_id() -> int:
	return reference_id
