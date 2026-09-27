class_name MessageBox
extends CanvasLayer

## In-game message box and HUD notification UI for Gamebryo MESG records.
## Handles both modal choice dialogs (with ITXT buttons) and corner toast notifications.

signal button_clicked(button_index: int)

@onready var _dialog_root: Control = $DialogRoot
@onready var _title_label: Label = $DialogRoot/Panel/Margin/VBox/Title
@onready var _body_label: RichTextLabel = $DialogRoot/Panel/Margin/VBox/Body
@onready var _buttons_container: VBoxContainer = $DialogRoot/Panel/Margin/VBox/ButtonsScroll/Buttons
@warning_ignore("unused_private_class_variable")
@onready var _buttons_scroll: ScrollContainer = $DialogRoot/Panel/Margin/VBox/ButtonsScroll

@onready var _toast_root: Control = $ToastRoot
@onready var _toast_panel: PanelContainer = $ToastRoot/ToastPanel
@onready var _toast_label: Label = $ToastRoot/ToastPanel/Margin/ToastLabel

var _previous_mouse_mode: Input.MouseMode = Input.MOUSE_MODE_CAPTURED
var _is_dialog_active: bool = false
var _button_nodes: Array[Button] = []
var _toast_tween: Tween = null
## Notifications waiting for the current one to fade: [{text, display_time}].
var _toast_queue: Array[Dictionary] = []


func _ready() -> void:
	_dialog_root.visible = false
	_toast_root.visible = false
	if _toast_panel:
		_toast_panel.modulate.a = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if not _is_dialog_active:
		return

	if event is InputEventKey and event.is_pressed() and not event.is_echo():
		# Number keys 1..9 to select button directly
		if event.keycode >= KEY_1 and event.keycode <= KEY_9:
			var idx: int = event.keycode - KEY_1
			if idx < _button_nodes.size():
				_on_button_pressed(idx)
				get_viewport().set_input_as_handled()
				return

		# Enter / Space selects the first button or currently focused
		if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			var focused := get_viewport().gui_get_focus_owner()
			if focused is Button and focused in _button_nodes:
				var idx := _button_nodes.find(focused as Button)
				_on_button_pressed(idx)
			elif not _button_nodes.is_empty():
				_on_button_pressed(0)
			get_viewport().set_input_as_handled()
			return

		# Escape dismisses with the last button option
		if event.keycode == KEY_ESCAPE:
			if not _button_nodes.is_empty():
				_on_button_pressed(_button_nodes.size() - 1)
				get_viewport().set_input_as_handled()
				return


## Seconds a notification stays up when its MESG has no TNAM display time.
const DEFAULT_DISPLAY_TIME := 5.0

## Displays a parsed MESG record dictionary:
## { "form_id": int, "editor_id": String, "title": String, "text": String,
##   "buttons": PackedStringArray, "is_message_box": bool, "flags": int, "display_time": float }
func display_message(msg: Dictionary) -> void:
	var is_box: bool = bool(msg.get("is_message_box", true))
	var buttons: Array = msg.get("buttons", [])

	if is_box or not buttons.is_empty():
		_show_modal_dialog(msg)
	else:
		_show_toast_notification(msg)


func _show_modal_dialog(msg: Dictionary) -> void:
	var title: String = String(msg.get("title", ""))
	var text: String = String(msg.get("text", ""))
	var buttons: Array = msg.get("buttons", [])

	if title.strip_edges().is_empty():
		_title_label.visible = false
	else:
		_title_label.visible = true
		_title_label.text = title

	_body_label.text = text

	# Clear previous buttons
	for b in _buttons_container.get_children():
		b.queue_free()
	_button_nodes.clear()

	# Populate ITXT buttons (or single default OK button)
	if buttons.is_empty():
		_add_dialog_button(0, "OK")
	else:
		for i in buttons.size():
			_add_dialog_button(i, String(buttons[i]))

	_previous_mouse_mode = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_is_dialog_active = true
	_dialog_root.visible = true

	# Auto-focus the first button
	if not _button_nodes.is_empty():
		_button_nodes[0].grab_focus()


func _add_dialog_button(index: int, label_text: String) -> void:
	var btn := Button.new()
	btn.text = "%d.  %s" % [index + 1, label_text] if label_text != "OK" else "OK"
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.custom_minimum_size = Vector2(0, 42)
	btn.add_theme_font_size_override("font_size", 16)
	btn.pressed.connect(_on_button_pressed.bind(index))
	_buttons_container.add_child(btn)
	_button_nodes.append(btn)


func _on_button_pressed(index: int) -> void:
	if not _is_dialog_active:
		return
	_is_dialog_active = false
	_dialog_root.visible = false
	Input.mouse_mode = _previous_mouse_mode
	button_clicked.emit(index)


## Queues a notification; notifications show one after another, each for its
## display time.
func _show_toast_notification(msg: Dictionary) -> void:
	var text: String = String(msg.get("text", ""))
	if text.strip_edges().is_empty():
		text = String(msg.get("title", ""))
	if text.strip_edges().is_empty():
		return
	_toast_queue.append({
		"text": text,
		"display_time": maxf(float(msg.get("display_time", DEFAULT_DISPLAY_TIME)), 1.0),
	})
	if _toast_tween == null or not _toast_tween.is_valid():
		_show_next_toast()

func _show_next_toast() -> void:
	if _toast_queue.is_empty():
		_toast_root.visible = false
		_toast_tween = null
		return
	var toast: Dictionary = _toast_queue.pop_front()
	_toast_label.text = String(toast["text"])
	_toast_root.visible = true
	_toast_panel.modulate.a = 0.0
	_toast_tween = create_tween()
	_toast_tween.tween_property(_toast_panel, "modulate:a", 1.0, 0.2)
	_toast_tween.tween_interval(float(toast["display_time"]))
	_toast_tween.tween_property(_toast_panel, "modulate:a", 0.0, 0.4)
	_toast_tween.tween_callback(_show_next_toast)
