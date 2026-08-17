extends Node3D

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"
const OUT_DIR := "/tmp/claude-1000/-var-home-lewin-Desktop-Claude-New-Vegas-Port/25351c50-84b1-4b51-9007-bf88d1e3cf75/scratchpad/"

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func load_texture(bsa: BsaReader, path: String) -> Image:
	var data := bsa.extract(path)
	if data.size() == 0:
		return null
	var img := Image.new()
	# Image.load()/load() does not recognize .dds (ERR_FILE_UNRECOGNIZED) —
	# DDS needs the dedicated load_dds_from_buffer() entry point. See
	# phases/0/04-dds-texture-import.md for the full finding.
	var err := img.load_dds_from_buffer(data)
	if err != OK:
		print("  FAIL load_dds_from_buffer(", path, ") -> error ", err)
		failures += 1
		return null
	return img

func build_submesh(nif: NifReader, index: int) -> ArrayMesh:
	var pos_flat := nif.get_positions(index)
	var norm_flat := nif.get_normals(index)
	var uv_flat := nif.get_uvs(index)
	var idx_flat := nif.get_indices(index)

	var verts := PackedVector3Array()
	verts.resize(pos_flat.size() / 3)
	for i in range(verts.size()):
		verts[i] = Vector3(pos_flat[i * 3], pos_flat[i * 3 + 1], pos_flat[i * 3 + 2])

	var normals := PackedVector3Array()
	if norm_flat.size() == pos_flat.size():
		normals.resize(norm_flat.size() / 3)
		for i in range(normals.size()):
			normals[i] = Vector3(norm_flat[i * 3], norm_flat[i * 3 + 1], norm_flat[i * 3 + 2])

	var uvs := PackedVector2Array()
	if uv_flat.size() == (pos_flat.size() / 3) * 2:
		uvs.resize(uv_flat.size() / 2)
		for i in range(uvs.size()):
			uvs[i] = Vector2(uv_flat[i * 2], uv_flat[i * 2 + 1])

	var indices := PackedInt32Array()
	indices.resize(idx_flat.size())
	for i in range(idx_flat.size()):
		indices[i] = idx_flat[i]

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	if normals.size() == verts.size():
		arrays[Mesh.ARRAY_NORMAL] = normals
	if uvs.size() == verts.size():
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	var mesh_bsa := BsaReader.new()
	check(mesh_bsa.open(DATA_DIR + "Update.bsa"), "opened Update.bsa (mesh source)")
	var tex_bsa := BsaReader.new()
	check(tex_bsa.open(DATA_DIR + "Fallout - Textures.bsa"), "opened Fallout - Textures.bsa")

	print("--- loading NVGuardTower01a.nif (0.2's STAT-resolved mesh, 0.3's mesh parser) ---")
	var nif_bytes := mesh_bsa.extract("meshes/architecture/ncr/nvguardtower01a.nif")
	check(nif_bytes.size() > 0, "extracted NIF from Update.bsa")
	var nif := NifReader.new()
	check(nif.load(nif_bytes), "NifReader.load() succeeded")
	var submesh_count := nif.get_submesh_count()
	check(submesh_count == 3, "3 submeshes as found in 0.3 (got %d)" % submesh_count)

	print("--- verifying DDS import (acceptance criteria: diffuse + normal map) ---")
	var diffuse_img := load_texture(tex_bsa, "textures/architecture/ncr/ncr_guardtower01.dds")
	check(diffuse_img != null, "diffuse texture loaded (BC1/DXT1)")
	if diffuse_img:
		print("  diffuse: ", diffuse_img.get_width(), "x", diffuse_img.get_height(),
				" format=", diffuse_img.get_format(), " mipmaps=", diffuse_img.get_mipmap_count())
		check(diffuse_img.get_format() == Image.FORMAT_DXT1, "diffuse decoded as FORMAT_DXT1 (BC1)")

	var normal_img := load_texture(tex_bsa, "textures/architecture/ncr/ncr_guardtower01_n.dds")
	check(normal_img != null, "normal map texture loaded (BC3/DXT5)")
	if normal_img:
		print("  normal: ", normal_img.get_width(), "x", normal_img.get_height(),
				" format=", normal_img.get_format(), " mipmaps=", normal_img.get_mipmap_count())
		check(normal_img.get_format() == Image.FORMAT_DXT5, "normal map decoded as FORMAT_DXT5 (BC3)")

	var urbansigns_img := load_texture(tex_bsa, "textures/architecture/urban/urbansigns.dds")
	check(urbansigns_img != null, "second diffuse texture (urbansigns, used by submeshes 1/2) loaded")

	print("--- building scene: one MeshInstance3D per NIF submesh, real textures applied ---")
	var diffuse_tex: ImageTexture = ImageTexture.create_from_image(diffuse_img) if diffuse_img else null
	var normal_tex: ImageTexture = ImageTexture.create_from_image(normal_img) if normal_img else null
	var urbansigns_tex: ImageTexture = ImageTexture.create_from_image(urbansigns_img) if urbansigns_img else null

	# NIF/Gamebryo is Z-up; Godot is Y-up. Rather than transform every vertex,
	# apply the axis change once at the root: -90 degrees about X maps
	# (x, y, z) -> (x, z, -y), the standard Z-up -> Y-up conversion. Known
	# limitation noted in 0.3's doc — this is where it gets addressed.
	rotation_degrees.x = -90

	var combined_aabb := AABB()
	var have_aabb := false

	for i in range(submesh_count):
		var mesh := build_submesh(nif, i)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.transform = nif.get_transform(i)

		var mat := StandardMaterial3D.new()
		var tex_path := nif.get_texture_path(i)
		if tex_path.to_lower().find("ncr_guardtower01") != -1:
			mat.albedo_texture = diffuse_tex
			if normal_tex:
				mat.normal_enabled = true
				mat.normal_texture = normal_tex
		elif tex_path.to_lower().find("urbansigns") != -1:
			mat.albedo_texture = urbansigns_tex
		mi.material_override = mat
		add_child(mi)

		var local_aabb: AABB = mesh.get_aabb()
		var world_aabb := mi.transform * local_aabb
		if not have_aabb:
			combined_aabb = world_aabb
			have_aabb = true
		else:
			combined_aabb = combined_aabb.merge(world_aabb)

	print("  combined (pre-Y-up-rotation) AABB: ", combined_aabb)

	var cam := Camera3D.new()
	add_child(cam)
	# combined_aabb is in the mesh's original Z-up space (children aren't
	# rotated, only the root is) — remap the same way for framing purposes:
	# (x, y, z) -> (x, z, -y).
	var center_zup: Vector3 = combined_aabb.get_center()
	var center := Vector3(center_zup.x, center_zup.z, -center_zup.y)
	var radius: float = combined_aabb.size.length() * 0.5
	var cam_dir := Vector3(1, 0.55, -0.4).normalized()
	cam.global_position = center + cam_dir * radius * 1.6
	cam.look_at(center, Vector3.UP)
	cam.far = radius * 10.0 + 100.0

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -30, 0)
	sun.light_energy = 1.3
	add_child(sun)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.5, 0.6, 0.75)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.55, 0.6)
	env.ambient_light_energy = 0.6
	env_node.environment = env
	add_child(env_node)

	get_viewport().transparent_bg = false

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	var img := get_viewport().get_texture().get_image()
	var out_path := OUT_DIR + "nvguardtower01a_textured.png"
	var save_err := img.save_png(out_path)
	check(save_err == OK, "saved screenshot to " + out_path)
	if save_err == OK:
		print("  screenshot: ", out_path, "  (", img.get_width(), "x", img.get_height(), ")")

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
