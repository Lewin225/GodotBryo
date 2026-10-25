extends Node

var DATA_DIR: String = GameDataConfig.resolve()["data_dir"] ## the launcher's data folder, or GODOTBRYO_DATA_DIR
const OUT_DIR := "/tmp/nv_test_screenshots/nif_test_output/" # stable, session-independent -- created fresh by make_dir_recursive_absolute() below regardless of who's running this

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func parse_one(bsa: BsaReader, bsa_path: String, label: String) -> Dictionary:
	print("--- ", label, " (", bsa_path, ") ---")
	var data := bsa.extract(bsa_path)
	check(data.size() > 0, "extracted non-empty from BSA")
	if data.size() == 0:
		return {}

	var reader := NifReader.new()
	var ok := reader.load(data)
	check(ok, "NifReader.load() succeeded (error: %s)" % reader.get_last_error())
	if not ok:
		return {}

	print("  nif version: ", reader.get_nif_version())
	var count := reader.get_submesh_count()
	print("  submesh count: ", count)
	check(count > 0, "at least one renderable submesh")

	var any_verts := false
	var any_indices := false
	var any_tex := false
	for i in range(count):
		var verts := reader.get_positions(i)
		var idx := reader.get_indices(i)
		var tex := reader.get_texture_path(i)
		if verts.size() > 0:
			any_verts = true
		if idx.size() > 0:
			any_indices = true
		if tex != "":
			any_tex = true
		@warning_ignore("integer_division")
		print("    [%d] %s  verts=%d  tris=%d  uvs=%d  normals=%d  tex='%s'" % [
			i, reader.get_submesh_name(i), verts.size() / 3, idx.size() / 3,
			reader.get_uvs(i).size() / 2, reader.get_normals(i).size() / 3, tex
		])

	check(any_verts, "at least one submesh has vertex positions")
	check(any_indices, "at least one submesh has triangle indices")
	check(any_tex, "at least one submesh has a texture path reference")

	return { "reader": reader, "count": count }

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	# The STAT record resolved in 0.2 (phases/0/02-esm-parser.md): FormID
	# 0x0017B7B5, EDID "NVGuardTower01a", MODL
	# "architecture\NCR\NVGuardTower01a.NIF". It turns out this particular
	# mesh isn't in the base "Fallout - Meshes.bsa" — it's an NV-specific
	# addition shipped in "Update.bsa" instead (confirmed by directory
	# search across all Data/*.bsa). That's a real, expected consequence of
	# BSA load order/precedence rather than a bug: 0.5's integration tool
	# will need to search Data BSAs in priority order, not assume everything
	# lives in one archive.
	var update_bsa := BsaReader.new()
	check(update_bsa.open(DATA_DIR + "Update.bsa"), "opened Update.bsa")
	var result := parse_one(update_bsa, "meshes/architecture/ncr/nvguardtower01a.nif",
			"STAT-resolved mesh from 0.2 (NVGuardTower01a)")
	if result.has("reader"):
		var path: String = OUT_DIR + "nvguardtower01a.gltf"
		check(result["reader"].export_gltf(path), "exported .gltf")
		check(FileAccess.file_exists(path), "gltf file exists on disk: " + path)

	# A spread of other static meshes from different game areas/categories
	# in the main mesh archive, to catch node-type variety rather than
	# overfitting to one file (acceptance criteria: at least 5 different
	# meshes). Paths confirmed to exist via a directory listing pass first.
	var bsa := BsaReader.new()
	check(bsa.open(DATA_DIR + "Fallout - Meshes.bsa"), "opened Fallout - Meshes.bsa")

	var candidates := [
		"meshes/ammo/10mmammo.nif",
		"meshes/weapons/2handrifle/sniperriflecarbonfibersuppressor.nif",
		"meshes/furniture/school/schooldeskadirty01.nif",
		"meshes/clutter/bobblehead/bobbleheadbart.nif",
		"meshes/creatures/radroach/roach.nif",
		"meshes/vehicles/b29/b29_bombanim01.nif",
		"meshes/dungeons/nv_casinolo/nv_ultralux/nv_ultraluxgalstairssider02.nif",
		"meshes/trees/nv_jtown_trees/nv_redced01.nif",
		"meshes/architecture/nellis afb/nvnellishangarinteriorcenterexl01.nif",
	]

	var tested := 0
	var multi_submesh_found := false
	for path in candidates:
		var data := bsa.extract(path)
		if data.size() == 0:
			print("--- skip (not found in this BSA): ", path, " ---")
			continue
		var r := parse_one(bsa, path, "sample mesh")
		if r.has("reader"):
			tested += 1
			if int(r["count"]) > 1:
				multi_submesh_found = true
				var out_path: String = OUT_DIR + path.get_file().get_basename() + ".gltf"
				r["reader"].export_gltf(out_path)

	check(tested >= 5, "at least 5 sample meshes (beyond the STAT one) parsed successfully (got %d)" % tested)
	check(multi_submesh_found, "at least one multi-submesh NIF found among samples")

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
