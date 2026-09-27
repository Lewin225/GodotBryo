extends Node3D

# 1.0 — Interior Cell Loader (STAT-only). See phases/1/00-interior-cell-loader.md.

const DATA_DIR := "../fresh_nv_copy/Data/"
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

# Same approximation as native/tools/dump_object.cpp / test_integration.gd.
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

func get_reader(archive_name: String) -> BsaReader:
	if bsa_readers.has(archive_name):
		return bsa_readers[archive_name]
	var r := BsaReader.new()
	if not r.open(DATA_DIR + archive_name):
		bsa_readers[archive_name] = null
		return null
	bsa_readers[archive_name] = r
	return r

func resolve(rel_path: String) -> Dictionary:
	for archive_name in bsa_order:
		var r := get_reader(archive_name)
		if r == null:
			continue
		var data := r.extract(rel_path)
		if data.size() > 0:
			return { "bsa": archive_name, "data": data }
	return {}

func build_submesh(nif: NifReader, index: int) -> ArrayMesh:
	var pos_flat := nif.get_positions(index)
	var norm_flat := nif.get_normals(index)
	var uv_flat := nif.get_uvs(index)
	var idx_flat := nif.get_indices(index)

	var verts := PackedVector3Array()
	@warning_ignore("integer_division")
	verts.resize(pos_flat.size() / 3)
	for i in range(verts.size()):
		verts[i] = Vector3(pos_flat[i * 3], pos_flat[i * 3 + 1], pos_flat[i * 3 + 2])

	var normals := PackedVector3Array()
	if norm_flat.size() == pos_flat.size():
		@warning_ignore("integer_division")
		normals.resize(norm_flat.size() / 3)
		for i in range(normals.size()):
			normals[i] = Vector3(norm_flat[i * 3], norm_flat[i * 3 + 1], norm_flat[i * 3 + 2])

	var uvs := PackedVector2Array()
	@warning_ignore("integer_division")
	if uv_flat.size() == (pos_flat.size() / 3) * 2:
		@warning_ignore("integer_division")
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

# Bethesda REFR.DATA rotation: X/Y/Z Euler radians, angles NEGATED before
# building each per-axis rotation (OpenMW cross-check, phases/1/00-interior-
# cell-loader.md). Composition order corrected in Phase 2 — see
# gamebryo/mesh_resolver.gd's refr_basis() and
# phases/2/03-refr-rotation-order.md for the finding (the OpenMW-derived
# `zr*yr*xr` order doesn't hold for FO3/NV; `xr*yr*zr` does, confirmed
# against a real visual counterexample).
func refr_basis(rot: Vector3) -> Basis:
	var bx := Basis(Vector3(1, 0, 0), -rot.x)
	var by := Basis(Vector3(0, 1, 0), -rot.y)
	var bz := Basis(Vector3(0, 0, 1), -rot.z)
	return bx * by * bz

func load_stat_placements(esm: EsmReader, cell_form_id: int) -> Array:
	var refs: Array = esm.get_cell_references(cell_form_id)
	var stats: Array = []
	var skipped := {}
	for r in refs:
		var bt: String = r["base_type"]
		if bt == "STAT":
			stats.append(r)
		else:
			skipped[bt] = skipped.get(bt, 0) + 1
	if not skipped.is_empty():
		print("  skipped (non-STAT, 1.1's job): ", skipped)
	return stats

func place_cell(root: Node3D, placements: Array) -> Dictionary:
	var placed := 0
	var failed := 0
	var combined_aabb := AABB()
	var have_aabb := false

	for p in placements:
		var model_path: String = "meshes\\" + String(p["model"])
		var mesh_found := resolve(model_path)
		if mesh_found.is_empty():
			print("  FAIL model not found: ", model_path)
			failed += 1
			continue

		var nif := NifReader.new()
		if not nif.load(mesh_found["data"]):
			print("  FAIL NIF parse: ", model_path, " (", nif.get_last_error(), ")")
			failed += 1
			continue

		var count := nif.get_submesh_count()
		if count == 0:
			failed += 1
			continue

		var anchor := StaticBody3D.new()
		anchor.name = String(p["editor_id"]) if String(p["editor_id"]) != "" else "REFR_%d" % int(p["refr_form_id"])
		var pos: Vector3 = p["position"]
		var rot: Vector3 = p["rotation"]
		var placement_scale: float = p["scale"]
		anchor.transform = Transform3D(refr_basis(rot) * Basis().scaled(Vector3.ONE * placement_scale), pos)
		root.add_child(anchor)

		for i in range(count):
			var mesh := build_submesh(nif, i)
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.transform = nif.get_transform(i)

			var tex_path := nif.get_texture_path(i)
			if tex_path != "":
				var tex_found := resolve(tex_path)
				if not tex_found.is_empty():
					var img := Image.new()
					if img.load_dds_from_buffer(tex_found["data"]) == OK:
						var mat := StandardMaterial3D.new()
						mat.albedo_texture = ImageTexture.create_from_image(img)
						mi.material_override = mat
			anchor.add_child(mi)

			var world_aabb: AABB = anchor.transform * (mi.transform * mesh.get_aabb())
			combined_aabb = world_aabb if not have_aabb else combined_aabb.merge(world_aabb)
			have_aabb = true

		placed += 1

	return { "placed": placed, "failed": failed, "aabb": combined_aabb, "have_aabb": have_aabb }

var _cam: Camera3D
var _sun: DirectionalLight3D

func ensure_view_nodes() -> void:
	if _cam != null:
		return
	_cam = Camera3D.new()
	add_child(_cam)
	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-45, -30, 0)
	_sun.light_energy = 1.3
	add_child(_sun)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.5, 0.6, 0.75)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.65)
	env.ambient_light_energy = 0.7
	env_node.environment = env
	add_child(env_node)

# Repositions the single shared camera — a fresh Camera3D per cell doesn't
# become the active one automatically (Godot only auto-activates a camera
# if none is already current), so reusing and explicitly re-activating one
# avoids screenshotting through a stale camera pointed at freed geometry.
func setup_view(root: Node3D, aabb: AABB) -> void:
	root.rotation_degrees.x = -90 # NIF Z-up -> Godot Y-up, see phases/0/04
	ensure_view_nodes()

	var c: Vector3 = aabb.get_center()
	var center := Vector3(c.x, c.z, -c.y)
	var radius: float = max(aabb.size.length() * 0.5, 2.0) # floor was 50.0, tuned for the pre-units.h ~70x-oversized world
	var cam_dir := Vector3(0.9, 0.7, 0.9).normalized()
	_cam.global_position = center + cam_dir * radius * 1.2
	_cam.look_at(center, Vector3.UP)
	_cam.far = radius * 10.0 + 500.0
	_cam.make_current()

func test_cell(esm: EsmReader, label: String, lookup: Dictionary, screenshot_name: String) -> void:
	print("=== ", label, " ===")
	check(not lookup.is_empty(), "cell found")
	if lookup.is_empty():
		return
	var form_id := int(lookup["form_id"])

	var placements := load_stat_placements(esm, form_id)
	print("  STAT placements: ", placements.size())
	check(placements.size() > 0, "at least one STAT placement")

	var cell_root := Node3D.new()
	add_child(cell_root)
	var result := place_cell(cell_root, placements)
	print("  placed=", result["placed"], " failed=", result["failed"])
	check(int(result["placed"]) > 0, "at least one object placed successfully")
	check(int(result["failed"]) == 0, "no failed placements (got %d failures)" % int(result["failed"]))

	if screenshot_name != "" and bool(result["have_aabb"]):
		setup_view(cell_root, result["aabb"])
		await get_tree().process_frame
		await get_tree().process_frame
		await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		if img == null:
			print("  (skipped screenshot -- no real viewport texture under --headless, expected)")
		else:
			var out_path := OUT_DIR + screenshot_name
			var save_err := img.save_png(out_path)
			check(save_err == OK, "saved screenshot to " + out_path)

	cell_root.queue_free()

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	build_bsa_order()

	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")

	# Default target, looked up by EditorID and separately by FormID —
	# acceptance criterion: both resolve to the same cell.
	var by_edid: Dictionary = esm.find_cell_by_editor_id("GSDocMitchellHouse")
	var by_formid: Dictionary = esm.find_cell_by_form_id(0x00103DF9)
	check(not by_edid.is_empty() and not by_formid.is_empty(), "found by both EDID and FormID")
	check(by_edid.get("form_id", -1) == by_formid.get("form_id", -2),
			"EDID and FormID lookups agree (%s vs %s)" % [by_edid.get("form_id"), by_formid.get("form_id")])

	await test_cell(esm, "GSDocMitchellHouse (default, by EDID)", by_edid, "doc_mitchell_house.png")

	# A second, different interior cell via the same generic code path —
	# proves the lookup isn't secretly specific to the default cell.
	var second: Dictionary = esm.find_cell_by_editor_id("RanchHouseInterior03")
	await test_cell(esm, "RanchHouseInterior03 (second cell, generic lookup)", second, "ranch_house_interior03.png")

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
