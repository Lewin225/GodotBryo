extends Node

# Issue #52 chunk 4: real-data verification that GamebryoMeshResolver.
# populate_humanoid_skeleton() wires a real skeleton against a full
# humanoid assembly -- Characters\_Male\Skeleton.NIF (real hierarchical
# Bip01 chain, no skin data of its own) plus UpperBody.nif/LeftHand.nif/
# RightHand.nif (each with real BSDismemberSkinInstance data whose bone
# names resolve against the shared skeleton), the same NPC_/RACE structure
# confirmed real on issue #52's own chunk 2 gate. See also
# project/_diag/_diag_humanoid_assembly.gd, the investigation that
# confirmed this shape before this function was written.

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _ready() -> void:
	var resolver := GamebryoMeshResolver.new()
	var root := Node3D.new()
	add_child(root)

	var body_parts := [
		"characters\\_male\\upperbody.nif",
		"characters\\_male\\lefthand.nif",
		"characters\\_male\\righthand.nif",
	]
	var skeleton := resolver.populate_humanoid_skeleton(root, "characters\\_male\\skeleton.nif", body_parts)

	check(skeleton != null, "populate_humanoid_skeleton() returned a real Skeleton3D")
	if skeleton == null:
		_finish()
		return

	# Real data confirmed (see _diag_humanoid_assembly.gd's own output):
	# skeleton.nif has 66 scene nodes and 2 root nodes -- a real nested
	# chain, unlike a self-contained body-part file's flat list.
	check(skeleton.get_bone_count() == 66, "skeleton has all 66 real bones from skeleton.nif (got %d)" % skeleton.get_bone_count())
	var root_bones := 0
	for i in skeleton.get_bone_count():
		if skeleton.get_bone_parent(i) == -1:
			root_bones += 1
	check(root_bones == 2, "real nested hierarchy: 2 root bones, not one-bone-per-flat-entry (got %d)" % root_bones)
	check(skeleton.find_bone("Bip01 Spine1") != -1, "a real named bone (Bip01 Spine1) resolves")
	check(skeleton.get_bone_parent(skeleton.find_bone("Bip01 Spine1")) == skeleton.find_bone("Bip01 Spine"),
			"Bip01 Spine1's parent is really Bip01 Spine -- a real chain, not flattened")

	var mesh_instances: Array = []
	for child in root.get_children():
		if child is MeshInstance3D:
			mesh_instances.append(child)
	# UpperBody.nif has 6 skin entries, LeftHand/RightHand 1 each (see
	# _diag_humanoid_assembly.gd's output) -- 8 total across the assembly.
	check(mesh_instances.size() == 8, "8 MeshInstance3D built across all 3 body parts (got %d)" % mesh_instances.size())

	var total_bad_binds := 0
	var total_verts := 0
	for mi in mesh_instances:
		check(mi.skin != null, "%s has a Skin resource" % mi.name)
		check(mi.mesh != null, "%s has an ArrayMesh" % mi.name)
		if mi.skin == null or mi.mesh == null:
			continue
		var bad_binds := 0
		for b in mi.skin.get_bind_count():
			if mi.skin.get_bind_bone(b) == -1:
				bad_binds += 1
		total_bad_binds += bad_binds
		check(bad_binds == 0, "%s: every skin bind resolves to the SHARED skeleton's own bones by name" % mi.name)

		var arrays: Array = mi.mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		total_verts += verts.size()
		# Same MeshInstance3D.skeleton wiring populate_skeleton() uses --
		# relative to the MeshInstance3D itself, not `root`.
		check(mi.get_node(mi.skeleton) == skeleton, "%s's MeshInstance3D.skeleton path resolves to the one shared Skeleton3D" % mi.name)

	check(total_bad_binds == 0, "zero total unresolved skin binds across the whole assembly")
	print("    bones=%d root_bones=%d mesh_instances=%d total_verts=%d" % [skeleton.get_bone_count(), root_bones, mesh_instances.size(), total_verts])

	# Real regression guard: a body part's own MODL/vertex data must never
	# have silently built a SECOND skeleton -- exactly one Skeleton3D child.
	var skeleton_children := 0
	for child in root.get_children():
		if child is Skeleton3D:
			skeleton_children += 1
	check(skeleton_children == 1, "exactly one Skeleton3D child under root (not one per body part)")

	_finish()

func _finish() -> void:
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
