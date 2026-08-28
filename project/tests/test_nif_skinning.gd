extends Node

# Issue #46 Phase D: real-data verification that GamebryoMeshResolver.
# populate_skeleton() builds a working Skeleton3D + Skin + MeshInstance3D
# set from a real NIF's skinning data (BSDismemberSkinInstance/NiSkinInstance
# + NiSkinData + NiSkinPartition -- see nif_types.h's own SkinData doc
# comment and native/tools/nif_skin_weights.cpp for the equivalent
# native-side check). This is the actual visual bug that started the whole
# investigation ("bones as cubes" on a real flag NIF outside Goodsprings
# docs house) -- a headless data-level check here, plus a manual visual
# confirmation in nif_viewer.tscn (this task's own acceptance step, not
# repeatable headlessly).

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

## `expect_hierarchical`: false for a body-part mesh (upperbody.nif) whose
## bones are a confirmed-real FLAT list in-file (every parent_index == -1 --
## the actual hierarchical "Bip01" chain lives in a separate shared
## skeleton.nif this issue doesn't load, see populate_skeleton()'s own doc
## comment); true for a small standalone-skinned prop (the flag) that
## carries its own real nested hierarchy since it has no external skeleton
## to depend on.
func check_skeleton(resolver: GamebryoMeshResolver, model_path: String, label: String, expect_hierarchical: bool) -> void:
	print("--- ", label, " (", model_path, ") ---")
	var nif := resolver.load_nif(model_path)
	check(nif != null, "NifReader loaded " + model_path)
	if nif == null:
		return

	var skin_entries: Array = nif.get_skin_data()
	check(not skin_entries.is_empty(), "NIF has real skin data")
	if skin_entries.is_empty():
		return

	var root := Node3D.new()
	add_child(root)
	var skeleton := resolver.populate_skeleton(root, nif, model_path)
	check(skeleton != null, "populate_skeleton() returned a real Skeleton3D")
	if skeleton == null:
		root.queue_free()
		return

	check(skeleton.get_bone_count() > 0, "skeleton has at least one bone (got %d)" % skeleton.get_bone_count())

	var root_bones := 0
	for i in skeleton.get_bone_count():
		if skeleton.get_bone_parent(i) == -1:
			root_bones += 1
	if expect_hierarchical:
		check(root_bones < skeleton.get_bone_count(), "real nested hierarchy (root_bones=%d < bone_count=%d)" % [root_bones, skeleton.get_bone_count()])
	else:
		check(root_bones == skeleton.get_bone_count(), "confirmed-flat in-file bone list (root_bones == bone_count == %d)" % root_bones)

	var mesh_instance_count := 0
	var total_bad := 0
	var total_verts := 0
	for child in root.get_children():
		if not (child is MeshInstance3D):
			continue
		mesh_instance_count += 1
		var mi: MeshInstance3D = child
		check(mi.skin != null, "%s has a Skin resource" % mi.name)
		check(mi.mesh != null, "%s has an ArrayMesh" % mi.name)
		if mi.skin == null or mi.mesh == null:
			continue

		var bad_binds := 0
		for b in mi.skin.get_bind_count():
			if mi.skin.get_bind_bone(b) == -1:
				bad_binds += 1
		total_bad += bad_binds
		check(bad_binds == 0, "%s: every skin bind resolves to a real skeleton bone" % mi.name)

		var arrays := mi.mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		check(bones.size() == verts.size() * 4, "%s: ARRAY_BONES is vertex_count*4" % mi.name)
		check(weights.size() == verts.size() * 4, "%s: ARRAY_WEIGHTS is vertex_count*4" % mi.name)
		total_verts += verts.size()

		var bad_weight_sum := 0
		for v in verts.size():
			var sum := 0.0
			for k in range(4):
				sum += weights[v * 4 + k]
			if sum < 0.8 or sum > 1.2:
				bad_weight_sum += 1
		check(bad_weight_sum == 0, "%s: every vertex's bone weights sum to ~1.0 (%d anomalies)" % [mi.name, bad_weight_sum])

	check(mesh_instance_count == skin_entries.size(), "one MeshInstance3D per skin entry (%d == %d)" % [mesh_instance_count, skin_entries.size()])
	print("    bones=%d root_bones=%d mesh_instances=%d total_verts=%d" % [skeleton.get_bone_count(), root_bones, mesh_instance_count, total_verts])

	root.queue_free()

func _ready() -> void:
	var resolver := GamebryoMeshResolver.new()

	check_skeleton(resolver, "characters\\_male\\upperbody.nif", "human upper body (BSDismemberSkinInstance)", false)
	check_skeleton(resolver, "creatures\\nvcazadores\\nvcazadores.nif", "Cazador creature (BSDismemberSkinInstance, wing bones)", false)
	check_skeleton(resolver, "clutter\\flags\\nv_ncr_flag.nif", "NCR flag (plain NiSkinInstance, self-contained hierarchy)", true)

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
