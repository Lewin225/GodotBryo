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
## The facing replaces the node's rotation only: its scale stays, authored or
## animated, as OpenMW's NIF billboard (AutoTransform) keeps the node's scale.
## The Fat Man explosion's fireball (FireBallGeo, RIGID_FACE_CENTER) grows
## through a transform track on this node; overwriting its whole basis lost the
## growth, and KfAnimator writing the track's transform after the facing left
## the fireball in its authored orientation, flat along the ground. The facing
## is therefore applied after animation, on RenderingServer.frame_pre_draw, to
## the base transform: the local transform as last set by anything other than
## this node (the authored one, or a track's).
##
## It costs a per-frame orientation per billboard node. That is the price of
## matching the source; the alternative was silently wrong geometry.

## The authored NiBillboardNode mode, verbatim. See _facing() for what each does.
@export var billboard_mode: String = "always_face_camera"

## The local axis that points at the viewer. Godot's convention is -Z forward,
## and NifServer's tree is already Y-up and Godot-facing by the time this runs.
const FACING := Vector3.BACK

## The local transform before facing: authored, or as a track last wrote it.
var _base := Transform3D.IDENTITY
## The local transform this node last wrote; a different one means something
## else (a track) set it since, and it becomes the base.
var _written := Transform3D.IDENTITY
var _has_written := false


func _ready() -> void:
	set_notify_transform(false)
	_base = transform


func _enter_tree() -> void:
	if not RenderingServer.frame_pre_draw.is_connected(_on_frame_pre_draw):
		RenderingServer.frame_pre_draw.connect(_on_frame_pre_draw)


func _exit_tree() -> void:
	if RenderingServer.frame_pre_draw.is_connected(_on_frame_pre_draw):
		RenderingServer.frame_pre_draw.disconnect(_on_frame_pre_draw)


func _on_frame_pre_draw() -> void:
	if not is_inside_tree():
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	if not _has_written or not transform.is_equal_approx(_written):
		_base = transform
	var facing: Variant = _facing(camera)
	if facing == null:
		return
	transform = _faced(facing)
	_written = transform
	_has_written = true


## The local transform that puts the node at its base origin and scale, turned
## to `facing` (a world rotation).
func _faced(facing: Basis) -> Transform3D:
	var parent := get_parent_node_3d()
	var parent_basis := parent.global_basis if parent != null else Basis.IDENTITY
	var world_scale := (parent_basis * _base.basis).get_scale()
	var world_basis := facing.orthonormalized().scaled_local(world_scale)
	return Transform3D(parent_basis.inverse() * world_basis, _base.origin)


## The world rotation the node faces with, or null when it has none this frame
## (the camera at the node, or on its up axis). The modes, as niftools'
## nif.xml describes them (read through a summary, not verbatim):
## "minimized" rotation (always_*) turns the node's authored facing (+Z) onto
## the target by the shortest arc, keeping its authored roll; "non-minimized"
## (rigid_*) snaps into the camera's frame, camera up; *_camera faces the
## camera's view plane, *_center the camera's position; rotate_about_up spins
## about the node's own up axis (its authored +Y, as OpenMW's AutoTransform),
## so a muzzle flash's flame card, authored along the barrel (+Y), turns about
## the barrel to face the viewer. # ASSUMPTION: bs_rotate_about_up behaves as
## rotate_about_up (nif.xml: rotates only about its local Z axis; its shapes
## not checked).
func _facing(camera: Camera3D) -> Variant:
	var parent := get_parent_node_3d()
	var parent_basis := parent.global_basis if parent != null else Basis.IDENTITY
	var origin := parent.global_transform * _base.origin if parent != null else _base.origin
	var authored := (parent_basis * _base.basis).orthonormalized()
	var to_camera := camera.global_position - origin
	match billboard_mode:
		"rotate_about_up", "bs_rotate_about_up":
			var axis := authored.y
			var across := to_camera - axis * to_camera.dot(axis)
			if across.length_squared() < 0.000001:
				return null
			var facing := across.normalized()
			return Basis(axis.cross(facing), axis, facing)
		"rigid_face_camera":
			return Basis.looking_at(-camera.global_basis.z, camera.global_basis.y)
		"rigid_face_center":
			if to_camera.length_squared() < 0.000001:
				return null
			return Basis.looking_at(-to_camera.normalized(), camera.global_basis.y)
		"always_face_center":
			if to_camera.length_squared() < 0.000001:
				return null
			return _turned_to(authored, to_camera.normalized())
		_:
			# always_face_camera: the view plane.
			return _turned_to(authored, camera.global_basis.z)


## `authored` turned by the shortest arc that puts its +Z on `facing`.
static func _turned_to(authored: Basis, facing: Vector3) -> Basis:
	var from := authored.z
	if from.dot(facing) < -0.9999:
		# Opposite: half a turn about the authored up axis.
		return Basis(authored.y, PI) * authored
	return Basis(Quaternion(from, facing)) * authored
