extends Node3D

# 0.5 integration test: exercises the *actual GDExtension wrappers*
# (EsmReader/BsaReader/NifReader/Image.load_dds_from_buffer) end-to-end,
# independently of native/tools/dump_object (which does the same pipeline
# in plain C++, no Godot). Two different implementations of the same
# BSA-priority-search + resolution pipeline agreeing is a stronger signal
# than either one alone.

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"
const OUT_DIR := "/tmp/nv_test_screenshots/" # stable, session-independent -- created fresh by make_dir_recursive_absolute() below regardless of who's running this

var failures := 0
var bsa_readers := {} # path -> BsaReader
var bsa_order: Array[String] = []

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

# Same approximation as native/tools/dump_object.cpp's priority_order():
# Update.bsa first, then DLC archives, then the base SArchiveList reversed,
# then anything else alphabetically. Not a real load-order simulation (see
# phases/0/05-integration-tool.md) — a Phase 0 approximation.
func build_bsa_order() -> void:
	var dir := DirAccess.open(DATA_DIR)
	var all_names: Array[String] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.to_lower().ends_with(".bsa"):
			all_names.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()

	var remaining := all_names.duplicate()
	var ordered: Array[String] = []

	if remaining.has("Update.bsa"):
		ordered.append("Update.bsa")
		remaining.erase("Update.bsa")

	var dlc: Array[String] = []
	for n in remaining:
		if not n.begins_with("Fallout - "):
			dlc.append(n)
	dlc.sort()
	for n in dlc:
		ordered.append(n)
		remaining.erase(n)

	var base_order := ["Fallout - Misc.bsa", "Fallout - Sound.bsa", "Fallout - Voices1.bsa",
			"Fallout - Meshes.bsa", "Fallout - Textures2.bsa", "Fallout - Textures.bsa"]
	for n in base_order:
		if remaining.has(n):
			ordered.append(n)
			remaining.erase(n)

	remaining.sort()
	for n in remaining:
		ordered.append(n)

	bsa_order = ordered

func get_reader(name: String) -> BsaReader:
	if bsa_readers.has(name):
		return bsa_readers[name]
	var r := BsaReader.new()
	if not r.open(DATA_DIR + name):
		bsa_readers[name] = null
		return null
	bsa_readers[name] = r
	return r

# Returns {bsa: String, data: PackedByteArray} or {} if not found in any archive.
func resolve(rel_path: String) -> Dictionary:
	for name in bsa_order:
		var r := get_reader(name)
		if r == null:
			continue
		var data := r.extract(rel_path)
		if data.size() > 0:
			return { "bsa": name, "data": data }
	return {}

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

# Full ESM -> BSA -> NIF -> DDS pipeline for one object, numeric checks only.
func resolve_object(esm: EsmReader, editor_id: String) -> Dictionary:
	print("--- ", editor_id, " ---")
	var stat: Dictionary = esm.find_stat_by_editor_id(editor_id)
	check(not stat.is_empty(), "ESM: STAT record found for " + editor_id)
	if stat.is_empty():
		return {}

	var model_path: String = "meshes\\" + String(stat["model"])
	var mesh_found := resolve(model_path)
	check(not mesh_found.is_empty(), "BSA: NIF located (" + model_path + ")")
	if mesh_found.is_empty():
		return {}
	print("  NIF from: ", mesh_found["bsa"])

	var nif := NifReader.new()
	check(nif.load(mesh_found["data"]), "NIF: parsed (" + nif.get_last_error() + ")")
	var count := nif.get_submesh_count()
	check(count > 0, "NIF: at least one submesh (got %d)" % count)
	print("  submeshes: ", count)

	var textures_resolved := 0
	var textures_total := 0
	var images := {} # texture_path -> Image
	for i in range(count):
		var tex_path := nif.get_texture_path(i)
		if tex_path == "" or images.has(tex_path):
			continue
		textures_total += 1
		var tex_found := resolve(tex_path)
		if tex_found.is_empty():
			continue
		var img := Image.new()
		if img.load_dds_from_buffer(tex_found["data"]) == OK:
			images[tex_path] = img
			textures_resolved += 1
	check(textures_resolved > 0, "DDS: %d/%d textures resolved and decoded" % [textures_resolved, textures_total])

	return { "nif": nif, "count": count, "images": images, "mesh_bsa": mesh_found["bsa"] }

func render_object(result: Dictionary, out_name: String) -> void:
	var nif: NifReader = result["nif"]
	var count: int = result["count"]
	var images: Dictionary = result["images"]

	var textures := {}
	for tex_path in images.keys():
		textures[tex_path] = ImageTexture.create_from_image(images[tex_path])

	var scene_root := Node3D.new()
	scene_root.rotation_degrees.x = -90 # NIF Z-up -> Godot Y-up, see phases/0/04
	add_child(scene_root)

	var combined_aabb := AABB()
	var have_aabb := false
	for i in range(count):
		var mesh := build_submesh(nif, i)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.transform = nif.get_transform(i)
		var tex_path := nif.get_texture_path(i)
		if textures.has(tex_path):
			var mat := StandardMaterial3D.new()
			mat.albedo_texture = textures[tex_path]
			mi.material_override = mat
		scene_root.add_child(mi)

		var world_aabb: AABB = mi.transform * mesh.get_aabb()
		combined_aabb = world_aabb if not have_aabb else combined_aabb.merge(world_aabb)
		have_aabb = true

	var cam := Camera3D.new()
	add_child(cam)
	var c: Vector3 = combined_aabb.get_center()
	var center := Vector3(c.x, c.z, -c.y)
	var radius: float = max(combined_aabb.size.length() * 0.5, 1.0)
	var cam_dir := Vector3(1, 0.55, -0.4).normalized()
	cam.global_position = center + cam_dir * radius * 1.0
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

func _ready() -> void:
	build_bsa_order()
	print("BSA search order: ", bsa_order)

	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")

	# The big stress test: 49 submeshes, 12 textures, from the auto-selected
	# dump_object run (phases/0/results.md) — a Hoover Dam interior piece.
	var hoover := resolve_object(esm, "NVHooverDamLowerL")
	if hoover.has("nif"):
		render_object(hoover, "nvhooverdamlowerl_textured.png")

	# A DLC-sourced object (Honest Hearts), numeric-only — confirms the
	# GDExtension pipeline also finds content outside the base BSAs/ESM.
	resolve_object(esm, "1stPerson127SMGsilencer")

	# Continuity check against 0.2/0.3/0.4's object (visual already
	# confirmed in 0.4 — numeric-only here).
	resolve_object(esm, "NVGuardTower01a")

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	if hoover.has("nif"):
		DirAccess.make_dir_recursive_absolute(OUT_DIR)
		var img := get_viewport().get_texture().get_image()
		if img == null:
			print("  (skipped screenshot -- no real viewport texture under --headless, expected)")
		else:
			var out_path := OUT_DIR + "nvhooverdamlowerl_textured.png"
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
