@tool
class_name NifBillboardNode
extends Node3D

## NiBillboardNode, as a node rather than as material state.
##
## Gamebryo rewrites the NODE's transform each frame so it faces the camera, and
## children inherit that rigidly. Godot's material billboard rewrites each mesh's
## model matrix independently, about its own origin -- which agrees only when the
## billboard node has exactly one shape sitting at its origin.
##
## Measured across meshes/effects/, 203 billboard nodes: 155 are that case, 11
## carry a single shape offset from the node by up to 4.75 m, and 35 hold several
## shapes that would counter-rotate against each other. So per-material billboard
## is wrong for roughly a quarter of them, and this exists instead.
##
## It costs a per-frame orientation per billboard node. That is the price of
## matching the source; the alternative was silently wrong geometry.

## The authored NiBillboardNode mode, verbatim. See _orient() for what each does.
@export var billboard_mode: String = "always_face_camera"

## The local axis that points at the viewer. Godot's convention is -Z forward,
## and NifServer's tree is already Y-up and Godot-facing by the time this runs.
const FACING := Vector3.BACK


func _ready() -> void:
	set_notify_transform(false)
	set_process(true)


func _process(_delta: float) -> void:
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera == null:
		return
	_orient(camera)


func _orient(camera: Camera3D) -> void:
	var up := Vector3.UP
	match billboard_mode:
		"rotate_about_up", "bs_rotate_about_up":
			# Spins about the world up axis only: the sprite stays upright and
			# turns to follow the viewer horizontally. Trees and flames.
			var to_cam := camera.global_position - global_position
			to_cam.y = 0.0
			if to_cam.length_squared() < 0.000001:
				return
			global_basis = Basis.looking_at(-to_cam.normalized(), up)
		"rigid_face_camera", "rigid_face_center":
			# "Rigid" faces the camera's view PLANE rather than the camera's
			# position, so a row of billboards stays mutually parallel instead
			# of fanning toward a point.
			global_basis = Basis.looking_at(-camera.global_basis.z, camera.global_basis.y)
		_:
			# always_face_camera / always_face_center: point at the camera
			# itself, so off-centre billboards turn toward it.
			var direction := camera.global_position - global_position
			if direction.length_squared() < 0.000001:
				return
			global_basis = Basis.looking_at(-direction.normalized(), up)
