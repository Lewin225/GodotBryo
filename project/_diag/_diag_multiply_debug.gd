extends SceneTree

func _init() -> void:
	var resolver := GamebryoMeshResolver.new()
	var model := "architecture\\hiddenvalley\\ecvhanger.nif"
	var nif := resolver.load_nif(model)
	print("submesh_count=", nif.get_submesh_count())
	for i in range(nif.get_submesh_count()):
		print(i, " name=", nif.get_submesh_name(i), " tex=", nif.get_texture_path(i),
			" alpha=", nif.get_alpha_info(i), " verts=", nif.get_positions(i).size() / 3)
	var geo := resolver.build_geometry_entries(resolver.resolve_raw_geometry(nif, model))
	print("mesh_entries.size()=", geo["mesh_entries"].size())
	for i in range(geo["mesh_entries"].size()):
		var mesh: ArrayMesh = geo["mesh_entries"][i]["mesh"]
		var mat := mesh.surface_get_material(0)
		print(i, " mat=", mat, " (", mat.blend_mode if mat != null and mat is StandardMaterial3D else "n/a", ")")
	quit()
