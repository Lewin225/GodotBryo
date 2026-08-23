extends SceneTree

func _init() -> void:
	var resolver := GamebryoMeshResolver.new()
	var model := "architecture\\hiddenvalley\\ecvhanger.nif"
	var nif := resolver.load_nif(model)
	var geo := resolver.build_geometry_entries(resolver.resolve_raw_geometry(nif, model))
	var entry: Dictionary = geo["mesh_entries"][4]
	var mesh: ArrayMesh = entry["mesh"]
	print("aabb=", mesh.get_aabb())
	print("transform=", entry["transform"])
	var mat := mesh.surface_get_material(0)
	print("mat albedo_color=", (mat as StandardMaterial3D).albedo_color)
	print("mat vertex_color_use_as_albedo=", (mat as StandardMaterial3D).vertex_color_use_as_albedo)
	var arrays := mesh.surface_get_arrays(0)
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	print("colors.size()=", colors.size())
	if colors.size() > 0:
		var avg := Color(0,0,0,0)
		for c in colors:
			avg += c
		avg /= colors.size()
		print("avg color=", avg)
	quit()
