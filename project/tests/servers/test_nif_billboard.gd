extends Node3D

## NifBillboardNode: faces the camera after animation and keeps the node's
## scale. A billboard at the origin with scale 2 faces a camera on +X; then a
## track-like write sets scale 3 and an unrelated rotation, and the node still
## faces the camera, at scale 3. (The Fat Man fireball, FireBallGeo, grows
## through a transform track on its billboard node; overwritten by the facing,
## it lost the growth, and left in the track's orientation it lay flat.)

const NifBillboardNodeScript := preload("res://GodotBryo/Servers/NifServer/nif_billboard_node.gd")
const FRAMES := 5

var failures := 0


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	var camera := Camera3D.new()
	add_child(camera)
	camera.position = Vector3(10, 0, 0)
	camera.look_at(Vector3.ZERO)
	camera.make_current()
	for mode in ["always_face_camera", "rigid_face_center", "rotate_about_up"]:
		await _check_mode(mode, camera)
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _check_mode(mode: String, camera: Camera3D) -> void:
	print("--- %s ---" % mode)
	var billboard: Node3D = NifBillboardNodeScript.new()
	billboard.billboard_mode = mode
	billboard.scale = Vector3(2, 2, 2)
	add_child(billboard)
	await _frames()
	_check_facing(billboard, camera, 2.0, "authored")
	# A track writes a new local transform: scale 3, rotated about Y.
	billboard.transform = Transform3D(Basis(Vector3.UP, 1.0).scaled(Vector3(3, 3, 3)), Vector3.ZERO)
	await _frames()
	_check_facing(billboard, camera, 3.0, "after a track sets scale 3 and a rotation")
	billboard.queue_free()


func _check_facing(billboard: Node3D, camera: Camera3D, scale: float, when: String) -> void:
	var basis := billboard.global_basis
	check(basis.get_scale().is_equal_approx(Vector3(scale, scale, scale)), "%s: scale %s kept (%s)" % [when, scale, basis.get_scale()])
	# The facing axis (+Z) points at the camera, which is on +X.
	var facing := basis.z.normalized()
	var to_camera := (camera.global_position - billboard.global_position).normalized()
	check(facing.dot(to_camera) > 0.99, "%s: +Z faces the camera (%s)" % [when, facing])


func _frames() -> void:
	for i in FRAMES:
		await RenderingServer.frame_post_draw
