class_name MouseCaptureManager
extends Node

## Optional: Custom action name if you define one in Project Settings -> Input Map.
## Defaults to checking KEY_ESCAPE directly if the action is not found.
@export var release_action: StringName = &"ui_cancel"

## If true, clicking into the game viewport recaptures the cursor.
@export var recapture_on_click: bool = true


func _input(event: InputEvent) -> void:
	# Release mouse on Escape (checks either the action map or the raw Key event)
	var is_escape := false
	if event is InputEventKey and event.pressed and not event.is_echo():
		if event.keycode == KEY_ESCAPE or event.physical_keycode == KEY_ESCAPE:
			is_escape = true
	if event.is_action_pressed(release_action):
		is_escape = true

	if is_escape:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			get_viewport().set_input_as_handled()
			return

	# Recapture mouse on left click if visible -- but not when the click
	# lands on an actual GUI Control (e.g. a MessageBox button). This runs
	# in _input(), which fires before Controls get their own _gui_input()
	# pass, so without this check every click on any in-game UI button
	# would be consumed here first and never reach the Control at all --
	# real, found the hard way testing the MessageBox dialog.
	if recapture_on_click and event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and get_viewport().gui_get_hovered_control() == null:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			get_viewport().set_input_as_handled()
