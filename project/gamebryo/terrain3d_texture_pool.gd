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
	# _set_asset()'s append path (terrain_3d_assets.cpp) assigns the real id as
	# the list's current size, ignoring the id argument beyond deciding
	# "append vs overwrite" -- passing TOTAL_SLOTS-1 here is just "definitely
	# append," the real assigned id is read back below, not assumed.
	_terrain.assets.set_texture(TOTAL_SLOTS - 1, asset)
	var id: int = _terrain.assets.get_texture_list().size() - 1
	_slot_by_texture[tex] = id
	return id

func _ensure_pink_slot() -> int:
	if _pink_slot >= 0:
		return _pink_slot
	var pink_img := Image.create(4, 4, false, Image.FORMAT_RGB8)
	pink_img.fill(Color(1.0, 0.0, 1.0))
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
