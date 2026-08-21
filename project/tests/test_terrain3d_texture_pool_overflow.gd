extends Node3D

# phases/2/13-terrain3d-integration.md, implementation step 6: real regression
# test for a bug found only in real play at real scale (a real ~31x31 cell area,
# not caught by any smaller isolated test) -- Terrain3DAssets::_update_texture_files()
# (terrain_3d_data.cpp) aborts rebuilding the ENTIRE albedo texture array the
# moment any one texture in the list fails its size/format/mipmap validation
# against the first texture. The original pink fallback (a fixed 4x4 RGB8 image)
# always failed this against real ~512x512 compressed ground textures, silently
# blocking every already-correctly-textured region from rendering too -- "all
# white" in real play.
#
# The control-map bit layout was later widened (base/overlay 5 bits -> 6 bits,
# see terrain_3d_util.h) specifically because region_size=256's real worst-case
# neighborhood need (49 distinct textures) exceeded the original 31-slot
# budget. At the new 63-slot budget, a real full-worldspace scan (all 16,388
# real WastelandNV cells) needs only 53 distinct ground textures total -- so
# real overflow through real game data is no longer reachable at all, which is
# the point of the first check below (a positive "real data comfortably fits"
# assertion, not an overflow-forcing one). The pink-fallback/overflow
# MECHANISM is still real code worth covering, so the second check forces it
# deterministically with synthetic textures instead of relying on real data
# that can no longer trigger it.

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
	_check_real_data_fits_budget()
	_check_synthetic_overflow_engages_fallback()
	finish()

## Real-data check: a substantial real cell area (the same ~31x31 area this
## test originally used to force overflow at the old 31-slot budget) now
## imports cleanly with distinct-texture usage comfortably under the new
## 63-slot budget -- confirming the bit-width widening's real payoff, and
## that Terrain3DAssets' size/format/mipmap validation never trips on real
## textures now that every texture is normalized (_normalize_texture()).
func _check_real_data_fits_budget() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")
	var resolver := GamebryoMeshResolver.new()
	var wrld: Dictionary = esm.find_worldspace_by_editor_id(WORLDSPACE_EDITOR_ID)
	var wrld_id := int(wrld.get("form_id", 0))

	var terrain := Terrain3DBridge.create_terrain(self)
	check(terrain.data != null, "Terrain3D.data initialized")
	var pool := Terrain3DTexturePool.new(terrain)
	var bridge := Terrain3DBridge.new(esm, resolver, pool)

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
	check(pool.used_slot_count() < Terrain3DTexturePool.USABLE_SLOTS,
			"real texture usage fits comfortably within budget (%d/%d slots used)" % [pool.used_slot_count(), Terrain3DTexturePool.USABLE_SLOTS])

	var texture_list: Array = terrain.assets.get_texture_list()
	check(texture_list.size() == pool.used_slot_count(),
			"no pink fallback needed for real data (%d texture(s) in list)" % texture_list.size())

## Synthetic check: USABLE_SLOTS+1 distinct fabricated textures (not tied to
## real game files, so this doesn't depend on how many distinct textures the
## real game happens to have) forced through the same pool.get_slot() path
## used in real play, to keep the overflow/pink-fallback mechanism itself
## under real test coverage even though real WastelandNV data can no longer
## reach it.
func _check_synthetic_overflow_engages_fallback() -> void:
	var terrain := Terrain3DBridge.create_terrain(self)
	var pool := Terrain3DTexturePool.new(terrain)

	var textures: Array[Texture2D] = []
	for i in range(Terrain3DTexturePool.USABLE_SLOTS + 1):
		var img := Image.create(4, 4, false, Image.FORMAT_RGB8)
		# Vary all three channels, not just one -- Image.compress()'s
		# COMPRESS_SOURCE_GENERIC heuristic picks a single-channel compressed
		# format (FORMAT_RGTC_R) for images that only vary one channel,
		# which would mismatch CANONICAL_FORMAT (FORMAT_DXT1) and trip the
		# same real Terrain3DAssets validation this test exists to cover --
		# a real multi-channel diffuse texture never hits this, so a
		# single-channel synthetic one shouldn't either.
		img.fill(Color(float(i) / 255.0, float((i * 37) % 256) / 255.0, float((i * 73) % 256) / 255.0))
		textures.append(ImageTexture.create_from_image(img))

	var slots: Array[int] = []
	for tex in textures:
		slots.append(pool.get_slot(tex))

	check(pool.used_slot_count() == Terrain3DTexturePool.USABLE_SLOTS,
			"synthetic overflow filled the real budget exactly (%d/%d slots used)" % [pool.used_slot_count(), Terrain3DTexturePool.USABLE_SLOTS])
	check(slots[-1] == Terrain3DTexturePool.USABLE_SLOTS,
			"the (USABLE_SLOTS+1)th distinct texture landed on the pink fallback slot (got %d)" % slots[-1])
	# Calling get_slot() again for the SAME overflowed texture must return the
	# SAME pink slot, not warn/allocate again.
	check(pool.get_slot(textures[-1]) == slots[-1],
			"repeat lookups of an overflowed texture stay pinned to the pink slot")

	var texture_list: Array = terrain.assets.get_texture_list()
	check(texture_list.size() == Terrain3DTexturePool.TOTAL_SLOTS,
			"texture list reached full capacity (%d/%d)" % [texture_list.size(), Terrain3DTexturePool.TOTAL_SLOTS])
	if texture_list.size() == Terrain3DTexturePool.TOTAL_SLOTS:
		var first_asset: Terrain3DTextureAsset = texture_list[0]
		var pink_asset: Terrain3DTextureAsset = texture_list[Terrain3DTexturePool.TOTAL_SLOTS - 1]
		var first_img := first_asset.get_albedo_texture().get_image()
		var pink_img := pink_asset.get_albedo_texture().get_image()
		check(pink_img.get_size() == first_img.get_size(),
				"pink fallback size matches first texture (%s vs %s)" % [pink_img.get_size(), first_img.get_size()])
		check(pink_img.get_format() == first_img.get_format(),
				"pink fallback format matches first texture (%d vs %d)" % [pink_img.get_format(), first_img.get_format()])
		check(pink_img.has_mipmaps() == first_img.has_mipmaps(),
				"pink fallback mipmap state matches first texture (%s vs %s)" % [pink_img.has_mipmaps(), first_img.has_mipmaps()])

func finish() -> void:
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
