class_name UnlockSession
extends CanvasLayer

## Placeholder lockpick / hacking screen: slide to the end to succeed, Cancel
## or Escape to give up. It changes no game state itself; whoever opens it
## reacts to `succeeded` or `cancelled`.

signal succeeded
signal cancelled

@onready var _title: Label = $Root/Panel/Margin/VBox/Title
@onready var _detail: Label = $Root/Panel/Margin/VBox/Detail
@onready var _slider: HSlider = $Root/Panel/Margin/VBox/Slider
@onready var _cancel: Button = $Root/Panel/Margin/VBox/Cancel

var _previous_mouse_mode: Input.MouseMode = Input.MOUSE_MODE_CAPTURED

func _ready() -> void:
	visible = false
	_slider.value_changed.connect(_on_slider_changed)
	_cancel.pressed.connect(cancel)

## Shows the screen with a title ("Lockpick", "Hack") and a detail line (the
## lock level).
func open(title: String, detail: String) -> void:
	_title.text = title
	_detail.text = detail
	_slider.set_value_no_signal(_slider.min_value)
	_previous_mouse_mode = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	visible = true

func cancel() -> void:
	if _close():
		cancelled.emit()

func _on_slider_changed(value: float) -> void:
	if value >= _slider.max_value and _close():
		succeeded.emit()

## Hides the screen; false when it was not open.
func _close() -> bool:
	if not visible:
		return false
	visible = false
	Input.mouse_mode = _previous_mouse_mode
	return true

func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		cancel()
		get_viewport().set_input_as_handled()
