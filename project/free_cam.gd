extends Camera3D

# Basic free-fly/no-clip camera. WASD to move, Space/Ctrl for up/down, mouse
# to look around, Shift to move faster, Escape to release the mouse (press
# again, or click the viewport, to recapture). Preview of the controller
# planned for 1.5 (phases/1/05-integration.md) — not that implementation,
# just enough to look around what 1.0 loads.

var move_speed := 4.0 # m/s — was 300 (tuned for a world still in raw Gamebryo
# units, ~70x too large; see gamebryo/mesh_resolver.gd's UNITS_TO_METERS)
var fast_multiplier := 4.0
var mouse_sensitivity := 0.003

var yaw := 0.0
var pitch := 0.0

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	var fwd := -global_transform.basis.z
	yaw = atan2(-fwd.x, -fwd.z)
	pitch = asin(clamp(fwd.y, -1.0, 1.0))

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * mouse_sensitivity
		pitch -= event.relative.y * mouse_sensitivity
		pitch = clamp(pitch, -1.5, 1.5)
		rotation = Vector3(pitch, yaw, 0.0)
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _process(delta: float) -> void:
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		dir -= global_transform.basis.z
	if Input.is_key_pressed(KEY_S):
		dir += global_transform.basis.z
	if Input.is_key_pressed(KEY_A):
		dir -= global_transform.basis.x
	if Input.is_key_pressed(KEY_D):
		dir += global_transform.basis.x
	if Input.is_key_pressed(KEY_SPACE):
		dir += Vector3.UP
	if Input.is_key_pressed(KEY_CTRL):
		dir -= Vector3.UP

	var speed := move_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= fast_multiplier

	if dir.length() > 0.0:
		global_position += dir.normalized() * speed * delta
