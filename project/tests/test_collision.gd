extends Node3D

# 1.2 — Collision Extraction. See phases/1/02-collision-extraction.md.
# Runs fully headless — PhysicsServer3D doesn't need a GPU/rendering
# context, unlike the visual-check tests.

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

# Recursively finds the first CollisionShape3D under `node` whose .shape
# matches `shape_class` (a Script/class reference, e.g. BoxShape3D), and
# whose own node name matches `name_filter` (a substring check, "" = any).
func find_collision(node: Node, shape_class, name_filter: String) -> CollisionShape3D:
	if node is CollisionShape3D and node.shape != null and is_instance_of(node.shape, shape_class):
		if name_filter == "" or String(node.name).contains(name_filter):
			return node
	for c in node.get_children():
		var found := find_collision(c, shape_class, name_filter)
		if found != null:
			return found
	return null

func _shape_local_center(shape: Shape3D) -> Vector3:
	if shape is BoxShape3D:
		return Vector3.ZERO # BoxShape3D is already centered on its CollisionShape3D's origin
	if shape is ConcavePolygonShape3D:
		var faces: PackedVector3Array = shape.get_faces()
		if faces.is_empty():
			return Vector3.ZERO
		var aabb := AABB(faces[0], Vector3.ZERO)
		for v in faces:
			aabb = aabb.expand(v)
		return aabb.get_center()
	return Vector3.ZERO

# World-space AABB of a CollisionShape3D's own geometry — used by the
# scale-sanity check below, and generic enough to reuse for the drop-target
# centering above if needed.
func _collision_world_aabb(col: CollisionShape3D) -> AABB:
	var shape := col.shape
	var local_aabb := AABB()
	var have := false
	if shape is ConcavePolygonShape3D:
		for v in shape.get_faces():
			if not have:
				local_aabb = AABB(v, Vector3.ZERO)
				have = true
			else:
				local_aabb = local_aabb.expand(v)
	elif shape is BoxShape3D:
		local_aabb = AABB(-shape.size / 2.0, shape.size)
		have = true
	elif shape is ConvexPolygonShape3D:
		for v in shape.points:
			if not have:
				local_aabb = AABB(v, Vector3.ZERO)
				have = true
			else:
				local_aabb = local_aabb.expand(v)
	if not have:
		return AABB()
	return col.global_transform * local_aabb

# Scale-sanity regression check: compares each object's collision geometry
# size against its OWN render mesh size. This is the actual check that
# caught the Havok unit-scale bug (collision was ~7x too small) — the
# physics drop test above did NOT catch it, because it targets the
# collision shape's own centroid, so a uniform scale error is invisible to
# a "does something stop the ball" test. Keeping both: the drop test proves
# collision physically works, this proves it's sized correctly relative to
# what you actually see.
func check_collision_scale_sanity(built_nodes: Array) -> void:
	var checked := 0
	var worst_ratio := 1.0
	for node in built_nodes:
		var render_aabb := AABB()
		var have_render := false
		for mi in _mesh_instances(node):
			var wb: AABB = mi.transform * mi.mesh.get_aabb()
			render_aabb = wb if not have_render else render_aabb.merge(wb)
			have_render = true
		if not have_render or render_aabb.size.length() < 0.01:
			continue

		for c in node.get_children():
			if not (c is CollisionShape3D):
				continue
			if String(c.name).contains("fallback"):
				continue # the fallback IS the render AABB by construction — not a useful sample
			if not (c.shape is ConcavePolygonShape3D or c.shape is ConvexPolygonShape3D or c.shape is BoxShape3D):
				continue # sphere/capsule don't have a comparable 3-axis "size"
			var col_aabb := _collision_world_aabb(c)
			# col_aabb is world-space (post node rotation); render_aabb is
			# local to the node — compare via diagonal length, which is
			# rotation-invariant, rather than per-axis.
			var render_diag := render_aabb.size.length()
			var col_diag := col_aabb.size.length()
			if render_diag < 0.01 or col_diag < 0.01:
				continue
			var ratio: float = col_diag / render_diag
			checked += 1
			if ratio < worst_ratio or (1.0 / ratio) < worst_ratio:
				worst_ratio = min(ratio, 1.0 / ratio)
			# Generous bounds — collision meshes are legitimately often
			# simplified/smaller than the visual mesh (e.g. "Bucket01" in
			# GSDocMitchellHouse sits right around 0.24 — plausibly a
			# collision proxy covering just the base, not the rim/handle),
			# but shouldn't be off by anywhere near the 7x this bug caused.
			check(ratio > 0.2 and ratio < 4.0,
					"%s: collision size within 4x of render mesh size (ratio=%.2f, render_diag=%.3fm, col_diag=%.3fm)" % [node.name, ratio, render_diag, col_diag])

	check(checked >= 10, "scale-sanity check ran against a real sample (got %d objects)" % checked)
	print("  scale-sanity: checked %d objects, worst ratio %.2f" % [checked, worst_ratio])

func spawn_drop_ball(pos: Vector3) -> RigidBody3D:
	var body := RigidBody3D.new()
	var col := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.1
	col.shape = shape
	body.add_child(col)
	add_child(body) # self (script root) is at identity, so local == global here
	body.position = pos
	return body

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")

	var resolver := GamebryoMeshResolver.new()
	var registry := GamebryoObjectRegistry.new(resolver, esm)

	var cell: Dictionary = esm.find_cell_by_editor_id("GSDocMitchellHouse")
	check(not cell.is_empty(), "cell found")
	var refs: Array = esm.get_cell_references(int(cell["form_id"]))

	var world := Node3D.new()
	world.rotation_degrees.x = -90
	add_child(world)

	# Build the cell exactly as 1.1 does, but also locate three specific
	# real objects to drop test balls onto: one with real triangle-mesh
	# collision, one with a real primitive shape, and one that resolved via
	# the no-bhk-data fallback bbox — found by inspecting the actual built
	# nodes, not guessed by EditorID.
	var triangle_col: CollisionShape3D = null
	var box_col: CollisionShape3D = null
	var fallback_col: CollisionShape3D = null
	var combined_aabb := AABB()
	var have_aabb := false
	var built_nodes: Array = []

	for p in refs:
		var node := registry.build(p)
		if node == null:
			continue
		world.add_child(node)
		built_nodes.append(node)

		if triangle_col == null:
			triangle_col = find_collision(node, ConcavePolygonShape3D, "")
		if box_col == null:
			var candidate := find_collision(node, BoxShape3D, "")
			if candidate != null and not String(candidate.name).contains("fallback"):
				box_col = candidate
		if fallback_col == null:
			fallback_col = find_collision(node, BoxShape3D, "fallback")

		for mi in _mesh_instances(node):
			var wb: AABB = mi.global_transform * mi.mesh.get_aabb()
			combined_aabb = wb if not have_aabb else combined_aabb.merge(wb)
			have_aabb = true

	check(triangle_col != null, "found a real object with triangle-mesh collision")
	check(box_col != null, "found a real object with box-primitive collision")
	check(fallback_col != null, "found an object using the no-bhk-data fallback bbox")
	check(have_aabb, "computed a cell AABB")

	print("--- scale sanity (collision size vs. own render mesh size) ---")
	check_collision_scale_sanity(built_nodes)

	var ceiling_y: float = combined_aabb.position.y + combined_aabb.size.y + 1.0

	# Drop onto the collision shape's own world-space AABB center — NOT the
	# object's pivot origin, which commonly isn't centered over its actual
	# geometry (e.g. a wall-mounted piece pivoting at its attach point).
	var drops := {}
	for entry in [["triangle", triangle_col], ["box", box_col], ["fallback", fallback_col]]:
		var label: String = entry[0]
		var col: CollisionShape3D = entry[1]
		if col == null:
			continue
		var world_center: Vector3 = col.global_transform * _shape_local_center(col.shape)
		var ball := spawn_drop_ball(Vector3(world_center.x, ceiling_y, world_center.z))
		drops[label] = ball

	# Let physics settle: compare Y at two checkpoints — still falling
	# significantly between them means nothing stopped it (broken/missing
	# collision); stable Y means it rested on real extracted geometry.
	await get_tree().create_timer(1.5).timeout
	var y_at_1_5s := {}
	for label in drops:
		y_at_1_5s[label] = drops[label].global_position.y

	await get_tree().create_timer(1.5).timeout
	for label in drops:
		var y_before: float = y_at_1_5s[label]
		var y_after: float = drops[label].global_position.y
		var delta := absf(y_after - y_before)
		var floor_min: float = combined_aabb.position.y - 0.5 # generous — some furniture sits below the nominal floor AABB min
		# Threshold distinguishes "resting, maybe still settling/rolling
		# slightly on an irregular real mesh" from "still in freefall" —
		# not "perfectly motionless". A ball in true freefall covers
		# roughly 20+ meters in a 1.5s window at this point in its fall
		# (already moving fast from the initial drop); a few tens of
		# centimeters of residual settling motion is expected and fine.
		check(delta < 1.0, "%s: settled (Y stable, moved %.4fm between checkpoints)" % [label, delta])
		check(y_after > floor_min, "%s: rested above the cell floor, not fallen through (y=%.2f, floor~%.2f)" % [label, y_after, combined_aabb.position.y])

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)

func _mesh_instances(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_mesh_instances(c))
	return out
