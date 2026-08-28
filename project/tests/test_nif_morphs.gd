extends Node

# Issue #47 Phase E: real-data verification that GamebryoMeshResolver.
# populate_skeleton() builds real Godot blend shapes from a NIF's morph
# target data (NiGeomMorpherController + NiMorphData), and that the
# resulting weight-animation AnimationPlayer plays back sane 0..1 weights
# over the real timeline -- see native/tools/nif_morph_check.cpp for the
# equivalent native-side check. Exercises the real Goodsprings
# NV_Nevadaflag.NIF, the one real asset issue #47 was filed against (a
# combined bone-rig-plus-cloth-ripple setup: skinning (#46) AND morphing on
# the same shape).

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _ready() -> void:
	var resolver := GamebryoMeshResolver.new()
	var model_path := "clutter\\flags\\nv_nevadaflag.nif"
	var nif := resolver.load_nif(model_path)
	check(nif != null, "NifReader loaded " + model_path)
	if nif == null:
		_finish()
		return

	var morph_entries: Array = nif.get_morph_data()
	check(morph_entries.size() == 2, "2 morph-capable submeshes (got %d)" % morph_entries.size())

	var root := Node3D.new()
	add_child(root)
	var skeleton := resolver.populate_skeleton(root, nif, model_path)
	check(skeleton != null, "populate_skeleton() returned a real Skeleton3D")

	var mesh_instances: Array = []
	var player: AnimationPlayer = null
	for child in root.get_children():
		if child is MeshInstance3D:
			mesh_instances.append(child)
		elif child is AnimationPlayer:
			player = child
	check(mesh_instances.size() == 2, "2 MeshInstance3D built (got %d)" % mesh_instances.size())
	check(player != null, "a MorphAnimationPlayer was built")

	for mi in mesh_instances:
		var mesh: ArrayMesh = mi.mesh
		check(mesh != null, "%s has an ArrayMesh" % mi.name)
		if mesh == null:
			continue
		# 8 real targets minus index 0 (the base shape's own copy -- see
		# nif_types.h's MorphTarget doc comment) == 7 real blend shapes.
		check(mesh.get_blend_shape_count() == 7, "%s has 7 blend shapes (got %d)" % [mi.name, mesh.get_blend_shape_count()])
		var arrays := mesh.surface_get_arrays(0)
		check(arrays[Mesh.ARRAY_BONES] != null and not (arrays[Mesh.ARRAY_BONES] as PackedInt32Array).is_empty(),
				"%s keeps its skinning (ARRAY_BONES) alongside its blend shapes" % mi.name)

	if player != null:
		var anim: Animation = player.get_animation("Morph")
		check(anim != null, "MorphAnimationPlayer has a 'Morph' animation")
		if anim != null:
			check(anim.get_track_count() == 14, "14 blend-shape tracks (2 shapes * 7 real targets, got %d)" % anim.get_track_count())
			for i in anim.get_track_count():
				check(anim.track_get_type(i) == Animation.TYPE_BLEND_SHAPE, "track %d is TYPE_BLEND_SHAPE" % i)
				check(anim.track_get_interpolation_type(i) == Animation.INTERPOLATION_LINEAR,
						"track %d uses LINEAR interpolation (CUBIC overshoots wildly on this spike-shaped data -- see mesh_resolver.gd's own doc comment)" % i)

			# Real regression check: sampling every weight across the whole
			# timeline must stay in-range (this is exactly what caught a
			# real CUBIC-interpolation overshoot bug -- a sampled weight of
			# -18.79 instead of 0..1 -- during Phase D's own verification).
			player.play("Morph")
			var out_of_range := 0
			var t := 0.0
			while t <= anim.length:
				player.seek(t, true)
				for mi in mesh_instances:
					for bi in mi.mesh.get_blend_shape_count():
						var w: float = mi.get_blend_shape_value(bi)
						if w < -0.01 or w > 1.01:
							out_of_range += 1
				t += 0.25
			check(out_of_range == 0, "every sampled blend-shape weight across the full timeline stays in 0..1 (%d out-of-range samples)" % out_of_range)

	_finish()

func _finish() -> void:
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
