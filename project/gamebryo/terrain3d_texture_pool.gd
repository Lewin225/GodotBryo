class_name Terrain3DTexturePool
extends RefCounted

## phases/2/13-terrain3d-integration.md's chosen texture-budget design: real,
## measured data (see that doc's "Real-data findings") shows region_size=64 keeps
## every realistic concurrently-resident neighborhood under Terrain3D's 32-slot
## control-map budget across the whole real worldspace (worst case 24 of 31 usable
## slots) -- so this pool does NOT implement LRU eviction yet (that machinery has
## never been exercised against a real trigger case; building it untested would be
## speculative complexity, not a real fix). What it DOES do, for real: assign each
## distinct texture its own slot (0..30), and once genuinely exhausted, hand out a
## reserved, unmissable solid-pink fallback texture instead of silently reusing/
## misassigning a slot -- the user's own framing for this design ("we'll see if we
## ever hit this in practice"). If real play ever shows the pink fallback firing,
## that's the real signal to build eviction, not a guess made in advance.
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
## naturally gives real textures ids 0..30 and the fallback (added only once, on
## first genuine overflow) id 31, matching this design's slot numbering without
## needing to force ids by hand.

const USABLE_SLOTS := 31 # ids 0..30
const TOTAL_SLOTS := 32 # id 31 is the pink fallback, added lazily on first overflow

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
	asset.set_albedo_texture(tex)
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

## Real bug found in real play (961-cell test area, well past 31 distinct real
## textures): Terrain3DAssets::_update_texture_files() (terrain_3d_assets.cpp)
## requires every texture in the list to share the EXACT SAME size/format/mipmap
## state as the first one -- a real, enforced requirement for building one GPU
## texture array, not a soft suggestion. A pink placeholder that doesn't match
## (this used to be a fixed 4x4 RGB8 image, unconditionally wrong) triggers
## `_terrain->set_warning(...)`, and _update_texture_files() checks
## `if (_terrain->get_warnings()) { return; }` BEFORE ever rebuilding the albedo
## array -- meaning a single mismatched texture blocks the WHOLE array from
## updating, not just its own slot. This is exactly what "goes all white" was:
## once real play streamed in more than 31 distinct ground textures (confirmed
## real, not hypothetical -- happens with a real ~31x31 cell area), the pink
## fallback's mismatched size broke every already-correctly-textured region's
## rendering too. Fixed by building the pink image to match the FIRST real
## texture's own actual size/format/mipmap state (queried directly, not assumed)
## instead of a fixed placeholder size.
func _ensure_pink_slot() -> int:
	if _pink_slot >= 0:
		return _pink_slot
	var pink_size := Vector2i(512, 512)
	var pink_format := Image.FORMAT_RGB8
	var pink_mipmaps := false
	var first_asset: Terrain3DTextureAsset = _terrain.assets.get_texture(0) if _terrain.assets.get_texture_list().size() > 0 else null
	if first_asset != null and first_asset.get_albedo_texture() != null:
		var first_img := first_asset.get_albedo_texture().get_image()
		if first_img != null:
			pink_size = first_img.get_size()
			pink_format = first_img.get_format()
			pink_mipmaps = first_img.has_mipmaps()
	# Real ground textures decode to a COMPRESSED format (BC1/BC3, this
	# project's own DDS pipeline -- see phases/0/04-dds-texture-import.md), and
	# Image.fill()/generate_mipmaps() both refuse to operate on compressed
	# formats directly (confirmed via a real error, not assumed) -- so this
	# always builds the pink placeholder uncompressed first, then compresses it
	# to match the real target format afterward if needed.
	var pink_img := Image.create(pink_size.x, pink_size.y, false, Image.FORMAT_RGB8)
	pink_img.fill(Color(1.0, 0.0, 1.0))
	if pink_mipmaps:
		pink_img.generate_mipmaps()
	if pink_format != Image.FORMAT_RGB8:
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
