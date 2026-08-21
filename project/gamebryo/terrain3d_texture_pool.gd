class_name Terrain3DTexturePool
extends RefCounted

## phases/2/13-terrain3d-integration.md's texture-budget design. Original
## real-data conclusion was region_size=64 (worst-case concurrent-neighborhood
## need: 24 of 31 usable slots) -- but region_size was later corrected to 256
## for an unrelated, higher-priority real bug (Terrain3D's fixed 32x32 region
## map didn't cover the real WastelandNV worldspace at region_size=64). At
## region_size=256, the real worst-case need (49) exceeds the original 31-slot
## budget, so the control-map format itself was widened: Terrain3D's base/
## overlay texture-ID fields grew from 5 bits (32 slots) to 6 bits (64 slots) --
## a real source patch to the vendored native/terrain3d addon (see
## terrain_3d_util.h's own comment on the full bit-layout change, which also
## had to move in lockstep across several GLSL shader files). USABLE_SLOTS/
## TOTAL_SLOTS below reflect that: 63 usable + 1 pink fallback. Still no LRU
## eviction (real overflow is possible in principle at very large concurrent
## areas, but hasn't been hit in real testing at this larger budget) -- if real
## play ever shows the pink fallback firing again, that's the signal to build
## eviction, not a guess made in advance.
##
## Uses Terrain3DAssets.set_texture(id, asset) one at a time, NOT
## set_texture_list() with a pre-sized array -- a real crash found while building
## this: Terrain3DAssets::_set_asset_list() (terrain_3d_assets.cpp) dereferences
## every array element's get_id() with no null check, so passing an array with
## empty/null slots (e.g. pre-sizing a 32-element array before all 32 are filled)
## segfaults inside the compiled addon. set_texture()'s own _set_asset() path
## appends new entries using the list's current size as the real assigned id
## (confirmed by reading its source, not assumed) -- so filling slots strictly
## sequentially, one real call per new texture, is both the crash-safe path and
## naturally gives real textures ids 0..62 and the fallback (added only once, on
## first genuine overflow) id 63, matching this design's slot numbering without
## needing to force ids by hand.

const USABLE_SLOTS := 63 # ids 0..62
const TOTAL_SLOTS := 64 # id 63 is the pink fallback, added lazily on first overflow

var _terrain: Terrain3D
var _slot_by_texture: Dictionary = {} # Texture2D -> int slot
var _pink_slot := -1 # -1 until a real overflow actually happens
var _overflow_warned: Dictionary = {} # Texture2D -> true, warn once per distinct overflowed texture

func _init(terrain: Terrain3D) -> void:
	_terrain = terrain

## Returns the slot id for `tex`, assigning a new one (via a real, sequential
## Terrain3DAssets.set_texture() call) if this is the first time this exact texture
## has been seen. Returns the pink fallback slot (added lazily, on first genuine
## overflow) once all 31 usable slots are taken, logging a warning exactly once per
## distinct texture that overflowed, so a real overflow is loud and greppable in
## real play, not silently wrong.
func get_slot(tex: Texture2D) -> int:
	if tex == null:
		return _ensure_pink_slot()
	if _slot_by_texture.has(tex):
		return _slot_by_texture[tex]
	if _slot_by_texture.size() >= USABLE_SLOTS:
		if not _overflow_warned.has(tex):
			_overflow_warned[tex] = true
			push_warning("Terrain3DTexturePool: texture budget exhausted (%d/%d slots used) -- %s falls back to solid pink. See phases/2/13-terrain3d-integration.md's texture-budget design." % [USABLE_SLOTS, USABLE_SLOTS, tex.resource_path])
		return _ensure_pink_slot()
	var asset := Terrain3DTextureAsset.new()
	asset.set_name("slot_%d" % _slot_by_texture.size())
	asset.set_albedo_texture(_normalize_texture(tex))
	# Real bug, same one reported against the old GamebryoTerrainBuilder
	# renderer: ground textures looked "far too scaled up." Terrain3D's own
	# Terrain3DTextureAsset.uv_scale defaults to 0.1 (uv = world_position *
	# uv_scale), meaning one texture tile spans 10 real-world meters --
	# matches the same "textures far too large" symptom, from a different
	# mechanism than the old renderer's own bug (that one used raw 0..1 UVs
	# across a whole ~29m quadrant; this is a per-texture world-space scale
	# constant instead). Matched to the same real-world tile size the old
	# renderer's fix uses -- one tile per VERTEX_SPACING interval (~1.83m,
	# terrain_builder.gd) -- for visual consistency between both renderers.
	asset.set_uv_scale(1.0 / Terrain3DBridge.VERTEX_SPACING)
	# _set_asset()'s append path (terrain_3d_assets.cpp) assigns the real id as
	# the list's current size, ignoring the id argument beyond deciding
	# "append vs overwrite" -- passing TOTAL_SLOTS-1 here is just "definitely
	# append," the real assigned id is read back below, not assumed.
	_terrain.assets.set_texture(TOTAL_SLOTS - 1, asset)
	var id: int = _terrain.assets.get_texture_list().size() - 1
	_slot_by_texture[tex] = id
	return id

## Real bug found in real play: Terrain3DAssets::_update_texture_files()
## (terrain_3d_assets.cpp) requires every texture in the list to share the
## EXACT SAME size/format/mipmap state as the first one -- a real, enforced
## requirement for building one GPU texture array, not a soft suggestion. Two
## real, separate ways this broke rendering entirely (not just one slot):
## (1) the pink placeholder not matching real ground textures (a ~31x31-cell
## test surfaced this first), and (2) REAL ground textures not matching EACH
## OTHER -- confirmed via a real full-worldspace scan: most `WastelandNV`
## ground textures are 512x512, but the `NV_Rocks` set is 1024x1024. Whichever
## texture happened to load FIRST silently determined the array's fixed size
## for the whole session, and every later texture (real or pink) at a
## different size broke the ENTIRE array, not just its own slot.
##
## Fixed properly instead of patched around: every texture entering this pool
## (real or pink) is normalized to one fixed canonical size/format/mipmap
## state via _normalize_texture() before ever becoming a Terrain3DTextureAsset,
## so "whichever texture loads first" can no longer matter. Canonical size is
## 512x512 (the real, dominant case -- confirmed via the same full-worldspace
## scan: only the `NV_Rocks` set needs downscaling, not the majority needing
## upscaling, the less lossy direction).
const CANONICAL_SIZE := 512
const CANONICAL_FORMAT := Image.FORMAT_DXT1 # BC1 -- this project's own confirmed real ground-texture format, phases/0/04-dds-texture-import.md

## Resizes/reformats `tex` to this pool's fixed canonical size/format/mipmap
## state if it doesn't already match, so it can never trigger the real
## Terrain3DAssets texture-array mismatch bug documented above. A no-op (just
## returns `tex` unchanged) for the common case where it already matches.
func _normalize_texture(tex: Texture2D) -> Texture2D:
	var img := tex.get_image()
	if img == null:
		return tex
	if img.get_size() == Vector2i(CANONICAL_SIZE, CANONICAL_SIZE) and img.get_format() == CANONICAL_FORMAT and img.has_mipmaps():
		return tex
	# Image.resize()/generate_mipmaps() both refuse to operate on compressed
	# formats directly (confirmed via a real error) -- decompress first,
	# resize/mipmap in an uncompressed format, then recompress to the
	# canonical target format.
	if img.is_compressed():
		img.decompress()
	if img.get_size() != Vector2i(CANONICAL_SIZE, CANONICAL_SIZE):
		img.resize(CANONICAL_SIZE, CANONICAL_SIZE, Image.INTERPOLATE_LANCZOS)
	# Drop any alpha channel before compressing -- Image.compress(COMPRESS_S3TC)
	# picks DXT1 vs DXT5 based on whether the source has non-opaque alpha
	# BYTES present, not visual appearance, so a real ground diffuse texture
	# that happens to carry stray non-255 alpha would otherwise silently
	# produce DXT5 and break the fixed CANONICAL_FORMAT guarantee this whole
	# normalization exists for.
	img.convert(Image.FORMAT_RGB8)
	img.generate_mipmaps()
	img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_GENERIC)
	return ImageTexture.create_from_image(img)

func _ensure_pink_slot() -> int:
	if _pink_slot >= 0:
		return _pink_slot
	# Built directly at the canonical size/format -- no longer needs to query
	# an existing texture's own state, since every real texture entering this
	# pool is normalized to the same canonical target (see _normalize_texture()
	# above), so the pink fallback can just target it directly instead of
	# copying whatever happened to load first.
	var pink_img := Image.create(CANONICAL_SIZE, CANONICAL_SIZE, false, Image.FORMAT_RGB8)
	pink_img.fill(Color(1.0, 0.0, 1.0))
	pink_img.generate_mipmaps()
	pink_img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_GENERIC)
	var pink_tex := ImageTexture.create_from_image(pink_img)
	var pink_asset := Terrain3DTextureAsset.new()
	pink_asset.set_name("__missing_texture_fallback")
	pink_asset.set_albedo_texture(pink_tex)
	_terrain.assets.set_texture(TOTAL_SLOTS - 1, pink_asset)
	_pink_slot = _terrain.assets.get_texture_list().size() - 1
	return _pink_slot

## Real slot count currently assigned to distinct textures (excludes the pink
## fallback, whether or not it's been added yet) -- for diagnostics/tests, not
## used by the assignment logic itself.
func used_slot_count() -> int:
	return _slot_by_texture.size()
