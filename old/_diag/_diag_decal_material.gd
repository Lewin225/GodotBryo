extends SceneTree

## Black-background decal investigation, step 2: run the REAL resolver
## pipeline on the exact NIFs the user reports (damage decals, cracks,
## cactus) and print what material actually comes out per submesh.

func _init() -> void:
	var resolver := GamebryoMeshResolver.new()
	var models := [
		"architecture\\generic\\damagedecal01.nif",
		"architecture\\urban\\decals\\nvcracksdecal.nif",
		"trees\\barrel_cactus\\nv_barrelcactus.nif",
		"landscape\\roads\\wastelandroadstrip01.nif", # DXT1 + alpha test (fix 1)
		"landscape\\trees\\treejoshanv_lod.nif", # DXT3 + threshold 0 (fix 2)
		"landscape\\roads\\wastelandroadstraightlong.nif", # DXT1 road surface + test 32
		"effects\\ambient\\industrial\\indfxlightrays01.nif", # additive light shaft (fix 3)
	]
	for m in models:
		var nif := resolver.load_nif(m)
		if nif == null:
			print(m, " -> NIF NOT FOUND")
			continue
		print("\n=== ", m, " ===")
		for i in range(nif.get_submesh_count()):
			print("  sub", i, " '", nif.get_submesh_name(i), "' tex=", nif.get_texture_path(i),
				" alpha=", nif.get_alpha_info(i), " unlit=", nif.is_unlit(i),
				" colors=", nif.get_colors(i).size())
		var geo := resolver.build_geometry_entries(resolver.resolve_raw_geometry(nif, m))
		var idx := 0
		for entry in geo["mesh_entries"]:
			var mesh: ArrayMesh = entry["mesh"]
			var mat: Material = mesh.surface_get_material(0)
			if mat == null:
				print("  built sub", idx, ": material=NULL (opaque default)")
			elif mat is StandardMaterial3D:
				var sm: StandardMaterial3D = mat
				var fmt := -1
				if sm.albedo_texture != null:
					fmt = (sm.albedo_texture as ImageTexture).get_image().get_format()
				print("  built sub", idx, ": transparency=", sm.transparency,
					" scissor=", sm.alpha_scissor_threshold,
					" blend_mode=", sm.blend_mode,
					" albedo_fmt=", fmt,
					" vtxcol=", sm.vertex_color_use_as_albedo,
					" shading=", sm.shading_mode)
			idx += 1
	quit()
