class_name ItemNode
extends GamebryoVisual

## Shared in-world representation for the Item branch. MISC is its first
## user; other item record types must prove their DATA layouts before joining.
var item_data: Dictionary = {}
var _body: GamebryoRigidBody
var _drag_camera: Camera3D = null
var _drag_started_msec := 0

func configure_item(data: Dictionary, form_id: int) -> void:
	item_data = data.duplicate()
	base_form_id = form_id

func attach_rigid_body(body: GamebryoRigidBody) -> void:
	_body = body

func pickup() -> Dictionary:
	if base_form_id == 0 or item_data.is_empty():
		return {}
	return { "base_form_id": base_form_id, "count": 1, "item_data": item_data.duplicate() }

func begin_drag(camera: Camera3D) -> bool:
	if _body == null or camera == null:
		return false
	_drag_camera = camera
	_drag_started_msec = Time.get_ticks_msec()
	_body.gravity_scale = 0.0
	_body.linear_damp = 8.0
	return true

func end_drag() -> void:
	_drag_camera = null
	_drag_started_msec = 0
	if _body != null:
		_body.gravity_scale = 1.0
		_body.linear_damp = 0.0

func _physics_process(_delta: float) -> void:
	if _drag_camera == null or _body == null:
		return
	# Force-following stays inside physics, unlike writing global_position
	# from _process() which fights Jolt and jitters against other props.
	var target := _drag_camera.global_position - _drag_camera.global_transform.basis.z * 1.6
	var delta := target - _body.global_position
	# A short soft lead-in avoids an abrupt jerk on press; after 0.5 seconds
	# the stronger spring firmly pulls a prop back into the carry position.
	var ramp: float = clampf(float(Time.get_ticks_msec() - _drag_started_msec) / 500.0, 0.0, 1.0)
	var spring: float = lerpf(45.0, 150.0, ramp)
	var damping: float = lerpf(14.0, 30.0, ramp)
	_body.apply_central_force(delta * _body.mass * spring - _body.linear_velocity * _body.mass * damping)
