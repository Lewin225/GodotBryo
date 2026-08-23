extends Node3D

# phases/2/07-runtime-cell-loader.md, Step 4. Headless physics test:
# raycast into a real, cell-loader-built DoorNode and confirm it's
# pickup-able and activate()-able exactly the way a player's own
# interaction code would use it.

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

## Combined world-space AABB of every CollisionShape3D under `node`, or null
## if it has none. CollisionShape3D has no get_aabb() of its own, so this
## reads each shape's local extent (BoxShape3D.size / raw vertex data per
## shape kind) rather than assuming one.
func _collision_world_aabb(node: Node) -> Variant:
	var have := false
	var combined := AABB()
	for shape_node in _collision_shapes(node):
		var local_aabb: Variant = _shape_local_aabb(shape_node.shape)
		if local_aabb == null:
			continue
		var corners := []
		var mn: Vector3 = local_aabb.position
		var mx: Vector3 = local_aabb.end
		for cx in [mn.x, mx.x]:
			for cy in [mn.y, mx.y]:
				for cz in [mn.z, mx.z]:
					corners.append(shape_node.global_transform * Vector3(cx, cy, cz))
		var wa := AABB(corners[0], Vector3.ZERO)
		for c in corners:
			wa = wa.expand(c)
		combined = wa if not have else combined.merge(wa)
		have = true
	return combined if have else null

func _collision_shapes(node: Node) -> Array:
	var out: Array = []
	if node is CollisionShape3D and node.shape != null:
		out.append(node)
	for c in node.get_children():
		out.append_array(_collision_shapes(c))
	return out

func _shape_local_aabb(shape: Shape3D) -> Variant:
	if shape is BoxShape3D:
		var he: Vector3 = shape.size * 0.5
		return AABB(-he, shape.size)
	if shape is ConcavePolygonShape3D or shape is ConvexPolygonShape3D:
		var pts: PackedVector3Array = shape.get_faces() if shape is ConcavePolygonShape3D else shape.points
		if pts.is_empty():
			return null
		var mn := pts[0]
		var mx := pts[0]
		for p in pts:
			mn = mn.min(p)
			mx = mx.max(p)
		return AABB(mn, mx - mn)
	return null

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")
	var doc_house: Dictionary = esm.find_cell_by_editor_id("GSDocMitchellHouse")

	var loader := CellLoader.new()
	add_child(loader)
	await get_tree().process_frame

	loader.load_cell(int(doc_house["form_id"]))
	while loader._loading:
		await get_tree().process_frame

	# Find the real GSDocMitchellDoor node the loader actually built (not a
	# synthetic one) inside CurrentCell/RefrRoot.
	var door: DoorNode = null
	var refr_root: Node = loader._current.get_node("RefrRoot")
	for c in refr_root.get_children():
		if c is DoorNode and c.name == "GSDocMitchellDoor":
			door = c
	check(door != null, "found the real GSDocMitchellDoor node built by the loader")
	if door == null:
		get_tree().quit(1)
		return
	check(door.has_destination, "door resolved a real destination at build time")

	# Real raycast, world-space, straight through the door's own COLLISION
	# volume (found from its real CollisionShape3D children), not through
	# door.global_position itself -- a door's REFR placement point sits at
	# its base/corner, not its geometric center (confirmed directly:
	# NVCraftsmanRmDoor's collision AABB starts within a centimeter of its
	# own origin on every axis, not centered on it -- see
	# native/src/nif/nif_loader.cpp's bhkRigidBodyT fix), so a ray through
	# the origin alone can graze past the actual solid volume.
	#
	# Cast along the AABB's own THINNEST axis (a door's real "thickness"
	# direction -- the way you'd actually walk through one), with just
	# enough margin past that axis's own extent, not a fixed wide sweep: a
	# fixed +-5 world-unit sweep along an arbitrary axis is easily wider than
	# a real interior room and clips straight through unrelated wall/frame
	# geometry in front of the door, hitting that instead (caught directly --
	# an earlier version of this fix hit an unrelated wall StaticBody3D, not
	# the door, using a fixed-axis, fixed-span probe).
	await get_tree().physics_frame
	await get_tree().physics_frame
	var col_aabb: Variant = _collision_world_aabb(door)
	check(col_aabb != null, "door has at least one CollisionShape3D to aim at")
	if col_aabb != null:
		var size: Vector3 = col_aabb.size
		var axis := Vector3.RIGHT
		var half_span: float = size.x
		if size.y <= size.x and size.y <= size.z:
			axis = Vector3.UP
			half_span = size.y
		elif size.z <= size.x and size.z <= size.y:
			axis = Vector3.BACK
			half_span = size.z
		half_span = half_span * 0.5 + 0.1 # small margin past the shape's own extent
		var center: Vector3 = col_aabb.get_center()
		var from: Vector3 = center + axis * half_span
		var to: Vector3 = center - axis * half_span
		var query := PhysicsRayQueryParameters3D.create(from, to)
		var space_state := get_world_3d().direct_space_state
		var result: Dictionary = space_state.intersect_ray(query)
		check(not result.is_empty(), "raycast toward the door's own collision volume hit something")
		if not result.is_empty():
			print("  raycast hit: ", result.get("collider"))
			# GamebryoReference is Node3D, not StaticBody3D (see
			# enginedocs/nv_class_hierarchy.md) -- the door's real collision
			# lives on an internal GamebryoCollisionBody child, so the
			# raycast collider is that body, not the DoorNode itself. A
			# caller resolves collider.owner_ref to reach the door (see
			# game.gd's interact raycast).
			var collider: Object = result["collider"]
			check(collider is GamebryoCollisionBody, "raycast collider is the door's composed GamebryoCollisionBody")
			if collider is GamebryoCollisionBody:
				check(collider.owner_ref == door, "collider.owner_ref resolves back to the real DoorNode")

	# activate() -- the actual interaction entry point a caller would call
	# once it's confirmed `hit_collider is DoorNode`.
	var dest: Dictionary = door.activate()
	check(not dest.is_empty(), "activate() returned real destination data")
	check(int(dest.get("dest_cell_form_id", 0)) == door.dest_cell_form_id, "activate()'s dest_cell_form_id matches the door's own resolved data")
	check(dest.get("dest_position", Vector3.ZERO) == door.dest_position, "activate()'s dest_position matches")

	# A non-teleporting door (NVCraftsmanHomeDoor, confirmed earlier this
	# session to have no XTEL) must return {} cleanly, not garbage/crash.
	var non_tele: DoorNode = null
	for c in refr_root.get_children():
		if c is DoorNode and c.name == "NVCraftsmanHomeDoor":
			non_tele = c
	check(non_tele != null, "found the non-teleporting NVCraftsmanHomeDoor")
	if non_tele != null:
		check(not non_tele.has_destination, "non-teleporting door correctly has_destination=false")

		# phases/3/00-door-completion.md step 8: activate() always toggles
		# is_open -- open/closed is real game-logic state, not merely a
		# label for whichever animation clip most recently played, so it
		# toggles even for a door with no animation/sound to show it (a
		# real, common case -- see step 4's own real-data census).
		check(non_tele.is_open == false, "non-teleporting door starts closed")
		check(non_tele.activate().is_empty(), "activate() on a non-teleporting door returns {} cleanly")
		check(non_tele.is_open == true, "activate() toggles is_open even with no animation/sound to show it")
		non_tele.activate()
		check(non_tele.is_open == false, "a second activate() toggles back to closed")

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
