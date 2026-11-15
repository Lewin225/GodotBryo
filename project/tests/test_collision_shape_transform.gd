extends Node3D

## A bhkConvexTransformShape places the shape it wraps. Havok stores the
## matrix column-major, the translation in [12..14] (all 166 transform shapes
## in the shipped NIFs). RamshackleBusDoor02.nif's door panel is a box under
## one, about 2 m from the NIF's origin: VFSBusDoorSouthREF's panel box lies
## over its mesh, not at the node's origin, and the interact ray finds it.

const DOOR_ID := "VFSBusDoorSouthREF"

var failures := 0


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	var esm_server = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var door: EsmReference = esm_server.find_reference_by_editor_id(DOOR_ID)
	var node := EsmReferencePhysicaliser.new().physicalise(door, self)
	for frame in 600:
		await get_tree().process_frame
		if not node.find_children("*", "CollisionShape3D", true, false).is_empty():
			break
	for frame in 4:
		await get_tree().physics_frame
	var mesh_box := AABB()
	var first := true
	for mesh: MeshInstance3D in node.find_children("*", "MeshInstance3D", true, false):
		var box := mesh.global_transform * mesh.get_aabb()
		mesh_box = box if first else mesh_box.merge(box)
		first = false
	var shapes := node.find_children("*", "CollisionShape3D", true, false)
	check(shapes.size() == 2, "%s has 2 collision boxes (%d)" % [DOOR_ID, shapes.size()])
	var panel_over_mesh := false
	var any_at_origin := false
	for shape: CollisionShape3D in shapes:
		var extent: Vector3 = (shape.shape as BoxShape3D).size if shape.shape is BoxShape3D else Vector3.ZERO
		var world_box := shape.global_transform * AABB(-extent / 2.0, extent)
		if mesh_box.grow(0.1).encloses(world_box) and world_box.get_volume() > mesh_box.get_volume() * 0.8:
			panel_over_mesh = true
		if shape.global_position.distance_to(node.global_position) < 0.01:
			any_at_origin = true
	check(panel_over_mesh, "the panel box covers the door's mesh (%s)" % mesh_box)
	check(not any_at_origin, "no box sits at the node's origin")

	var ray := RayCast3D.new()
	add_child(ray)
	var centre := mesh_box.get_center()
	ray.global_position = centre + Vector3(2.0, 0.0, 0.0)
	ray.target_position = Vector3(-4.0, 0.0, 0.0)
	ray.force_raycast_update()
	var hit_target := InteractRay.semantic_target(ray.get_collider()) if ray.is_colliding() else null
	check(hit_target == node, "a ray across the door's centre finds the door node (%s)" % hit_target)
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
