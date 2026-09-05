@tool
class_name MotionData
extends Resource

## Renderer-neutral movement state supplied by a player or AI controller.
@export var velocity: Vector3 = Vector3.ZERO
@export var planar_velocity: Vector3 = Vector3.ZERO
@export var grounded: bool = true
@export var crouched: bool = false
@export var sprinting: bool = false

func update_from_velocity(value: Vector3, is_grounded: bool = true) -> void:
	velocity = value
	planar_velocity = Vector3(value.x, 0.0, value.z)
	grounded = is_grounded
