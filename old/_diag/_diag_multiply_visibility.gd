extends Node3D

## Simplified: perspective camera looking straight at the multiply shape's
## own AABB center from a fixed distance, no custom offset math, isolating
## whether it's a real rendering/blend problem or a framing bug in the
## earlier diag.

func _ready() -> void:
	var resolver := GamebryoMeshResolver.new()
	var model := "architecture\\hiddenvalley\\ecvhanger.nif"
	var nif := resolver.load_nif(model)
	var geo := resolver.build_geometry_entries(resolver.resolve_raw_geometry(nif, model))
	var entry: Dictionary = geo["mesh_entries"][4]
	var mesh: ArrayMesh = entry["mesh"]

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.5, 0.5, 0.5)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	# Sparse geometry (dirt-streak decal, mostly empty bounding box) --
	# confirmed real via the red-unlit-override pass; this pass uses the
	# PIPELINE'S OWN material (real multiply blend + real vertex color) to
	# confirm streaks actually darken the mid-gray backdrop where they draw.
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	add_child(mi)

	var aabb := mesh.get_aabb()
	print("aabb=", aabb)
	var center := aabb.get_center()
	var radius := aabb.size.length()

	var cam := Camera3D.new()
	cam.position = center + Vector3(0, 0, radius * 1.5 + 1.0)
	cam.look_at(center, Vector3.UP)
	cam.far = radius * 10.0 + 100.0
	add_child(cam)

	for i in range(5):
		await get_tree().process_frame

	var shot := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("/tmp/nv_test_screenshots")
	shot.save_png("/tmp/nv_test_screenshots/_diag_multiply_visibility.png")
	get_tree().quit()
