extends Node3D

# phases/2/13-terrain3d-integration.md, implementation step 6: real regression
# test for a bug found only in real play at real scale (a real ~31x31 cell area,
# not caught by any smaller isolated test) -- Terrain3DAssets::_update_texture_files()
# (terrain_3d_data.cpp) aborts rebuilding the ENTIRE albedo texture array the
# moment any one texture in the list fails its size/format/mipmap validation
# against the first texture. The original pink fallback (a fixed 4x4 RGB8 image)
# always failed this against real ~512x512 compressed ground textures, silently
# blocking every already-correctly-textured region from rendering too -- "all
# white" in real play. This forces real overflow (more than
# Terrain3DTexturePool.USABLE_SLOTS distinct real textures) and confirms the
# texture array still builds without a validation error.

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"
const WORLDSPACE_EDITOR_ID := "WastelandNV"

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")
	var resolver := GamebryoMeshResolver.new()
	var wrld: Dictionary = esm.find_worldspace_by_editor_id(WORLDSPACE_EDITOR_ID)
	var wrld_id := int(wrld.get("form_id", 0))

	var terrain := Terrain3DBridge.create_terrain(self)
	check(terrain.data != null, "Terrain3D.data initialized")
	var pool := Terrain3DTexturePool.new(terrain)
	var bridge := Terrain3DBridge.new(esm, resolver, pool)

	# A real, wide enough real-cell area to genuinely exceed
	# Terrain3DTexturePool.USABLE_SLOTS (31) distinct ground textures -- confirmed
	# via a real scratch diagnostic during this bug's investigation that a real
	# ~31x31 cell area around Goodsprings does exactly this.
	var imported := 0
	for dx in range(-15, 16):
		for dy in range(-15, 16):
			var gx := -17 + dx
			var gy := 0 + dy
			var cell: Dictionary = esm.find_exterior_cell(wrld_id, gx, gy)
			if cell.is_empty():
				continue
			if bridge.import_cell(terrain, int(cell["form_id"])):
				imported += 1
	check(imported > 100, "imported a real, substantial cell area (%d cells)" % imported)
	check(pool.used_slot_count() >= Terrain3DTexturePool.USABLE_SLOTS,
			"real overflow actually happened (%d/%d slots used)" % [pool.used_slot_count(), Terrain3DTexturePool.USABLE_SLOTS])

	# The real bug: does Terrain3D's own texture-array validation reject the
	# pink fallback? get_texture_list() reflects real added assets regardless,
	# but the actual signal this bug produces is a real ERROR log line from
	# Terrain3DAssets::_update_texture_files() -- not directly queryable from
	# GDScript, so this checks the two things that ARE queryable and were
	# actually wrong before the fix: the fallback texture's size/format/mipmap
	# state now matches the first real texture's (the real validation
	# Terrain3D itself performs), confirmed directly here too.
	var texture_list: Array = terrain.assets.get_texture_list()
	check(texture_list.size() == Terrain3DTexturePool.TOTAL_SLOTS,
			"texture list reached full capacity (%d/%d)" % [texture_list.size(), Terrain3DTexturePool.TOTAL_SLOTS])
	if texture_list.size() == Terrain3DTexturePool.TOTAL_SLOTS:
		var first_asset: Terrain3DTextureAsset = texture_list[0]
		var pink_asset: Terrain3DTextureAsset = texture_list[Terrain3DTexturePool.TOTAL_SLOTS - 1]
		var first_img := first_asset.get_albedo_texture().get_image()
		var pink_img := pink_asset.get_albedo_texture().get_image()
		check(pink_img.get_size() == first_img.get_size(),
				"pink fallback size matches first real texture (%s vs %s)" % [pink_img.get_size(), first_img.get_size()])
		check(pink_img.get_format() == first_img.get_format(),
				"pink fallback format matches first real texture (%d vs %d)" % [pink_img.get_format(), first_img.get_format()])
		check(pink_img.has_mipmaps() == first_img.has_mipmaps(),
				"pink fallback mipmap state matches first real texture (%s vs %s)" % [pink_img.has_mipmaps(), first_img.has_mipmaps()])

	finish()

func finish() -> void:
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
