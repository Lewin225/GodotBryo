extends Node3D

## Blend-function fix verification (REAL GPU render, DISPLAY=:0): renders
## the real, unmodified per-shape ArrayMesh + material for one mix, one
## additive (light shaft), and one multiply shape, all resolved through the
## actual pipeline, over a mid-gray backdrop so additive brightening and
## multiply darkening are both visible against it (a green backdrop, used
## for the earlier alpha investigation, would swamp both effects). Uses the
## REAL resolved geometry (not a synthetic quad) so a texture-less,
## vertex-color-only decal like the multiply shape still shows its actual
## content instead of a stripped-down stand-in.

func _pipeline_mesh_entry(resolver: GamebryoMeshResolver, model: String, shape_name_contains: String) -> Dictionary:
	var nif := resolver.load_nif(model)
	if nif == null:
		return {}
	var geo := resolver.build_geometry_entries(resolver.resolve_raw_geometry(nif, model))
	var entries: Array = geo["mesh_entries"]
	for i in range(nif.get_submesh_count()):
		if shape_name_contains == "" or nif.get_submesh_name(i).to_lower().contains(shape_name_contains):
			if i < entries.size():
				return entries[i]
	return {}

func _ready() -> void:
	var resolver := GamebryoMeshResolver.new()

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.5, 0.5, 0.5)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 4.0
	cam.position = Vector3(0, 0, 5)
	add_child(cam)

	var specs := [
		{ "model": "architecture\\urban\\decals\\nvcracksdecal.nif", "shape": "", "x": -1.6, "label": "mix" },
		{ "model": "effects\\ambient\\industrial\\indfxlightrays01.nif", "shape": "", "x": 0.0, "label": "add" },
		{ "model": "architecture\\hiddenvalley\\ecvhanger.nif", "shape": "ecvhanger:4", "x": 1.6, "label": "multiply" },
	]
	for s in specs:
		var entry := _pipeline_mesh_entry(resolver, s["model"], s["shape"])
		if entry.is_empty():
			print("FAIL: no mesh entry for ", s["model"], "/", s["shape"])
			continue
		var mesh: ArrayMesh = entry["mesh"]
		var mat := mesh.surface_get_material(0)
		print(s["label"], " transparency=", (mat as StandardMaterial3D).transparency,
			" blend_mode=", (mat as StandardMaterial3D).blend_mode)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		# Frame each shape's own AABB into a roughly 1.5-unit box at its slot.
		var aabb := mesh.get_aabb()
		var extent := maxf(maxf(aabb.size.x, aabb.size.y), maxf(aabb.size.z, 0.001))
		var s3 := 1.5 / extent
		mi.position = Vector3(s["x"], 0, 0) - aabb.get_center() * s3
		mi.scale = Vector3.ONE * s3
		add_child(mi)

	for i in range(5):
		await get_tree().process_frame

	var shot := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("/tmp/nv_test_screenshots")
	shot.save_png("/tmp/nv_test_screenshots/_diag_blend_func_gpu.png")

	# Whole-slot luminance range vs the 0.5 gray backdrop: additive should
	# read brighter than backdrop somewhere in its slot, multiply darker,
	# straight alpha-mix just shows its own texture content.
	var w := shot.get_width()
	var h := shot.get_height()
	var horiz := 4.0 * float(w) / float(h)
	for s in specs:
		var cx := int((float(s["x"]) / horiz + 0.5) * w)
		var cy := int(h * 0.5)
		var x0 := cx - int(0.7 / horiz * w)
		var x1 := cx + int(0.7 / horiz * w)
		var y0 := cy - int(0.7 / 4.0 * h)
		var y1 := cy + int(0.7 / 4.0 * h)
		var max_lum := 0.0
		var min_lum := 1.0
		for y in range(maxi(y0, 0), mini(y1, h), 3):
			for x in range(maxi(x0, 0), mini(x1, w), 3):
				var c := shot.get_pixel(x, y)
				var lum := (c.r + c.g + c.b) / 3.0
				max_lum = maxf(max_lum, lum)
				min_lum = minf(min_lum, lum)
		print(s["label"], " -> min_lum=", min_lum, " max_lum=", max_lum, " (backdrop=0.5)")
	get_tree().quit()
