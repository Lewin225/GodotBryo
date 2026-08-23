extends Node3D

## Black-background decal fix verification (REAL GPU render — run with
## DISPLAY=:0, not --headless): same quad-census as the investigation
## version, but each quad's material now comes from the REAL pipeline
## (GamebryoMeshResolver.build_geometry_entries() on the actual NIF), so
## this exercises the alpha-safe DXT1 decompress + threshold clamp exactly
## as the game path builds them.
##
## Pre-fix census (investigation run, hand-built materials, same regions):
##   A (DXT1 road strip, scissor 0.125): black=6272 green(cut)=0
##   B (DXT3 joshua billboard, thresh 0): black=151*  green(cut)=0
##   (* census under-counted the billboard's dark-brown background as
##   "other"; the visual showed the full opaque square.)
## Post-fix expectation: green(cut) large, black ~0 for both.

func _pipeline_material(resolver: GamebryoMeshResolver, model: String, submesh: int) -> Material:
	var nif := resolver.load_nif(model)
	if nif == null:
		return null
	var geo := resolver.build_geometry_entries(resolver.resolve_raw_geometry(nif, model))
	var entries: Array = geo["mesh_entries"]
	if submesh >= entries.size():
		return null
	return (entries[submesh]["mesh"] as ArrayMesh).surface_get_material(0)

func _ready() -> void:
	var resolver := GamebryoMeshResolver.new()

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 1, 0)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 4.0
	cam.position = Vector3(0, 0, 5)
	add_child(cam)

	var specs := [
		# sub4 of the strip NIF = the roadwastelandStrip01.dds center-line
		# shape (threshold 32); sub0 of the tree LOD = the billboard.
		{ "model": "landscape\\roads\\wastelandroadstrip01.nif", "sub": 4, "x": -1.2, "label": "A_dxt1_strip" },
		{ "model": "landscape\\trees\\treejoshanv_lod.nif", "sub": 0, "x": 0.0, "label": "B_joshua_thresh0" },
		{ "model": "architecture\\urban\\decals\\nvcracksdecal.nif", "sub": 0, "x": 1.2, "label": "C_crack_decal" },
	]
	for s in specs:
		var mat := _pipeline_material(resolver, s["model"], s["sub"])
		if mat == null:
			print("FAIL: no material for ", s["model"])
			continue
		var sm := mat as StandardMaterial3D
		# The strip shapes are vertex-colored; a bare QuadMesh has no COLOR
		# array (defaults can render black) -- disable for the quad stand-in,
		# it's not the property under test.
		sm = sm.duplicate()
		sm.vertex_color_use_as_albedo = false
		sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		print(s["label"], " transparency=", sm.transparency, " scissor=", sm.alpha_scissor_threshold,
			" fmt=", (sm.albedo_texture as ImageTexture).get_image().get_format())
		var quad := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(1, 1)
		quad.mesh = qm
		quad.material_override = sm
		quad.position = Vector3(s["x"], 0, 0)
		add_child(quad)

	for i in range(5):
		await get_tree().process_frame

	var shot := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("/tmp/nv_test_screenshots")
	shot.save_png("/tmp/nv_test_screenshots/_diag_alpha_gpu_postfix.png")

	var w := shot.get_width()
	var h := shot.get_height()
	var horiz := 4.0 * float(w) / float(h)
	for s in specs:
		var cx := int((float(s["x"]) / horiz + 0.5) * w)
		var x0 := cx - int(0.5 / horiz * w) + 2
		var x1 := cx + int(0.5 / horiz * w) - 2
		var y0 := int(h * (0.5 - 0.5 / 4.0)) + 2
		var y1 := int(h * (0.5 + 0.5 / 4.0)) - 2
		var black := 0
		var green := 0
		var other := 0
		for y in range(y0, y1, 2):
			for x in range(x0, x1, 2):
				var c := shot.get_pixel(x, y)
				if c.g > 0.8 and c.r < 0.2:
					green += 1
				elif c.r < 0.12 and c.g < 0.12 and c.b < 0.12:
					black += 1
				else:
					other += 1
		print(s["label"], " -> black=", black, " green(cut)=", green, " other(content)=", other)
	get_tree().quit()
