extends Node3D

## Joshua-billboard black-fringe investigation (real GPU, DISPLAY=:0):
## hypothesis — at LOD-billboard distances the sampled mip levels have
## alpha averaged across black background texels, and a scissor floor of
## 1/255 keeps that near-transparent fringe as opaque black blobs.
## Renders the real treejosh_lod.dds at shrinking on-screen scales
## (forcing smaller mips), one row per scissor threshold, and counts
## black-ish pixels OUTSIDE what the full-res silhouette would cover.

func _ready() -> void:
	var resolver := GamebryoMeshResolver.new()
	var found := resolver.resolve_bytes("textures\\landscape\\trees\\treejosh_lod.dds")
	var img := Image.new()
	img.load_dds_from_buffer(found["data"])
	var tex := ImageTexture.create_from_image(img)

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

	var thresholds: Array[float] = [1.0 / 255.0, 0.25, 0.5]
	var scales: Array[float] = [1.0, 0.25, 0.1, 0.05]
	for row in range(thresholds.size()):
		for col in range(scales.size()):
			var mat := StandardMaterial3D.new()
			mat.albedo_texture = tex
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			mat.alpha_scissor_threshold = thresholds[row]
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			var quad := MeshInstance3D.new()
			var qm := QuadMesh.new()
			qm.size = Vector2(1, 1) * scales[col]
			quad.mesh = qm
			quad.material_override = mat
			quad.position = Vector3(-1.8 + col * 1.2, 1.2 - row * 1.2, 0)
			add_child(quad)

	for i in range(5):
		await get_tree().process_frame

	var shot := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("/tmp/nv_test_screenshots")
	shot.save_png("/tmp/nv_test_screenshots/_diag_billboard_fringe.png")

	# Census per cell: fraction of the quad's screen area that is black-ish.
	var w := shot.get_width()
	var h := shot.get_height()
	var horiz := 4.0 * float(w) / float(h)
	for row in range(thresholds.size()):
		var line := "thresh=%.4f:" % thresholds[row]
		for col in range(scales.size()):
			var cx := (-1.8 + col * 1.2) / horiz + 0.5
			var cy := 0.5 - (1.2 - row * 1.2) / 4.0
			var half := 0.5 * scales[col]
			var x0 := int((cx - half / horiz) * w)
			var x1 := int((cx + half / horiz) * w)
			var y0 := int((cy - half / 4.0) * h)
			var y1 := int((cy + half / 4.0) * h)
			var black := 0
			var n := 0
			for y in range(y0, y1):
				for x in range(x0, x1):
					n += 1
					var c := shot.get_pixel(x, y)
					if c.r < 0.15 and c.g < 0.15 and c.b < 0.15:
						black += 1
			line += "  scale=%.2f black=%d%%" % [scales[col], int(100.0 * black / maxi(n, 1))]
		print(line)
	get_tree().quit()
