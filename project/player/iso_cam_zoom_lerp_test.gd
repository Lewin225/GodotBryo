extends Camera3D

var target_size = self.size

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	self.size = lerpf(self.size, target_size, delta*5)

func _input(event:InputEvent):
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_WHEEL_DOWN):
		target_size = target_size + 1

	if Input.is_mouse_button_pressed(MOUSE_BUTTON_WHEEL_UP):
		target_size = target_size - 1

	if event.is_action_released("toggle_stats"):
			$".".current = !$".".current
			$"../../Camera3D".current = !$".".current
			$"../../NPCActor".possessed_first_person = $"../../Camera3D".current
