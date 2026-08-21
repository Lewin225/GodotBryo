class_name Terrain3DTexturePool
extends RefCounted

## phases/2/13-terrain3d-integration.md's texture-budget design. Original
## real-data conclusion was region_size=64 (worst-case concurrent-neighborhood
## need: 24 of 31 usable slots) -- but region_size was later corrected to 256
## for an unrelated, higher-priority real bug (Terrain3D's fixed 32x32 region
## map didn't cover the real WastelandNV worldspace at region_size=64). At
## region_size=256, the real worst-case need (49) exceeds the original 31-slot
## budget, so the control-map format was widened TWICE: Terrain3D's base/
## overlay texture-ID fields grew from 5 bits (32 slots) to 6 bits (64 slots),
## then from 6 to 7 bits (128 slots) after true per-vertex overlay selection
## (terrain3d_bridge.gd) revealed a real whole-worldspace need of 64 distinct
## textures -- over the 62-usable-slot budget the first widening left. Both
## are real source patches to the vendored native/terrain3d addon (see
## terrain_3d_util.h's own comment on the full bit-layout change, which also
## had to move in lockstep across several GLSL shader files). Superseded by
## phases/2/14-native-terrain-texture-blend.md, which replaces the control-map
## 2-texture format entirely with a real per-vertex N=7 layer format -- this
## pool's own 128-slot budget carries over unchanged (real worldspace need is
## still 64, comfortably inside it), but the control-map bit-width/NaN-guard
## concerns below no longer apply, since nothing writes texture IDs into the
## control map anymore. USABLE_SLOTS/TOTAL_SLOTS: 126 usable (1..126) + 1
## reserved default/unpainted placeholder (0, see _reserve_default_slot()) +
## 1 pink overflow fallback (127) = 128. Still no LRU eviction (real overflow
## is possible in
## principle at very large concurrent areas, but the real whole-worldspace
## need, 64, is nowhere close to this budget) -- if real play ever shows the
## pink fallback firing again, that's the signal to build eviction, not a
## guess made in advance.
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
## naturally gives real textures sequential ids and the fallback (added only
## once, on first genuine overflow) the final id, matching this design's slot
## numbering without needing to force ids by hand.

## RETIRED (phases/2/14-native-terrain-texture-blend.md): this pool used to
## reserve a throwaway slot to dodge a real IEEE-754 NaN collision --
## Terrain3D's control map stored texture IDs as a uint32 REINTERPRETED as a
## float32, and certain (base, overlay) ID combinations produced a bit
## pattern Terrain3DData::get_control() treated as an "invalid" sentinel,
## corrupting real painted data into visible rainbow/magenta garbage. Fixed
## twice (reserved slot 31, then 63) as the control map's bit width grew.
##
## That entire bug class is now structurally impossible: terrain3d_bridge.gd
## no longer writes texture IDs into the control map at all (see phases/2/14's
## integration plan step 4) -- real per-vertex IDs go into
## TYPE_TEX_ID_A/TYPE_TEX_ID_B, plain FORMAT_RGBA8 normalized channels
## decoded via round(sample*255.0) in the shader, never reinterpreted as bits.
## No reserved slot needed; USABLE_SLOTS is a plain budget again.
const USABLE_SLOTS := 126 # ids 1..126 (0 reserved -- see _reserve_default_slot(); 127 is the pink overflow fallback)
const TOTAL_SLOTS := 128

var _terrain: Terrain3D
var _slot_by_texture: Dictionary = {} # Texture2D -> int slot
var _pink_slot := -1 # -1 until a real overflow actually happens
var _overflow_warned: Dictionary = {} # Texture2D -> true, warn once per distinct overflowed texture

func _init(terrain: Terrain3D) -> void:
	_terrain = terrain
	_reserve_default_slot()

## Real fix for a live-play report of solid-white (or solid-whatever) terrain
## patches, static and reproducible rather than intermittent: ANY vertex
## whose real per-vertex texture-ID data was never actually written --
## terrain3d_bridge.gd's own "if base_slot[q] < 0: continue" (a quadrant with
## no real BTXT and no real ATXT to fall back on), or simply a region's
## default COLOR_ZERO before its own cell streams in -- decodes to real
## texture ID 0 at the shader's ALWAYS-FULL-WEIGHT implicit base layer (see
## main.glsl's accumulate_material(), phases/2/14-native-terrain-texture-
## blend.md). Before this fix, whichever real ground texture this session's
## pool happened to resolve FIRST silently became "the default texture for
## everywhere nothing was actually painted" -- an accident of resolution
## order, not a design choice. Once `prewarm_textures()` made resolution
## order deterministic (worldspace grid-scan order) instead of
## streaming-order-dependent, real slot 0 became a REAL, SPECIFIC, always-
## the-same ground texture -- and if that texture happens to be bright/pale,
## every unpainted vertex renders as a real, solid, unmistakably "corrupt"-
## looking patch of it, consistently, from the very first frame.
##
## Fixed by reserving real slot 0 for the same pink placeholder overflow
## already uses, added before any real texture ever gets resolved (so it's
## guaranteed to land at 0 -- Terrain3DAssets.set_texture()'s own
## append-by-list-size behavior, the same mechanism get_slot() already relies
## on for every other slot). "Nothing painted here" now visually says so
## honestly instead of silently showing an arbitrary real texture as if it
## had been deliberately painted.
## Dimmer than the full-brightness overflow pink (_build_pink_texture()'s own
## default) -- see that function's own comment for why. Still an obviously
## synthetic magenta, just not bright enough to blow out real HDR exposure
## across what's expected to be real, ordinary, large "not streamed in yet"
## screen area.
const DEFAULT_SLOT_COLOR := Color(0.35, 0.0, 0.35)

func _reserve_default_slot() -> void:
	var placeholder := Terrain3DTextureAsset.new()
	placeholder.set_name("__default_unpainted_placeholder")
	placeholder.set_albedo_texture(_build_pink_texture(DEFAULT_SLOT_COLOR))
	_terrain.assets.set_texture(TOTAL_SLOTS - 1, placeholder)

## Returns the slot id for `tex`, assigning a new one (via a real, sequential
## Terrain3DAssets.set_texture() call) if this is the first time this exact texture
## has been seen. Returns the pink fallback slot (added lazily, on first genuine
## overflow) once all 31 usable slots are taken, logging a warning exactly once per
## distinct texture that overflowed, so a real overflow is loud and greppable in
## real play, not silently wrong.
##
## `debug_name` (the real texture path, plumbed from _resolve_to_slot() in
## terrain3d_bridge.gd) is for diagnostics only. Real bug found while adding
## it: `tex.resource_path` (used directly in the overflow warning below before
## this) is ALWAYS empty for these textures -- they're built via
## ImageTexture.create_from_image() (mesh_resolver.gd's own
## _get_texture_from_image()), which never sets resource_path. Every real
## overflow warning this pool has ever logged named an empty string, silently
## useless for tracking down which real texture actually overflowed.
func get_slot(tex: Texture2D, debug_name: String = "") -> int:
	if tex == null:
		return _ensure_pink_slot()
	if _slot_by_texture.has(tex):
		return _slot_by_texture[tex]
	if _slot_by_texture.size() >= USABLE_SLOTS:
		if not _overflow_warned.has(tex):
			_overflow_warned[tex] = true
			push_warning("Terrain3DTexturePool: texture budget exhausted (%d/%d slots used) -- %s falls back to solid pink. See phases/2/13-terrain3d-integration.md's texture-budget design." % [USABLE_SLOTS, USABLE_SLOTS, debug_name])
		return _ensure_pink_slot()
	var asset := Terrain3DTextureAsset.new()
	asset.set_name("slot_%d" % _terrain.assets.get_texture_list().size())
	asset.set_albedo_texture(_normalize_texture(tex, debug_name))
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
##
## Real bug found via a live-play report (solid white patches with bloom
## glowing around them, appearing only after this pool started resolving
## EVERY real ATXT layer unconditionally instead of only "winning" ones --
## phases/2/14-native-terrain-texture-blend.md -- meaning real ground
## textures that had NEVER been loaded through this path before started
## hitting it for the first time): every fallible step here
## (decompress()/resize()/convert()/compress()) had its Error return code
## silently ignored. If any one of them fails on some real texture's
## particular encoding, the following steps operate on a still-wrong-format
## Image, and the final ImageTexture.create_from_image() can end up wrapping
## blank/garbage pixel data while still LOOKING like a valid canonical-format
## entry (right size, right format, right mipmap flag) -- passing
## Terrain3DAssets' own format/size/mipmap validation while actually being
## corrupt, worst of both worlds. Fixed by checking every step and falling
## back to the same canonical pink placeholder (loud, safe, already-proven
## degradation) instead of silently shipping whatever `img` ended up holding.
## `debug_name` (the real texture path, from _resolve_to_slot()) makes the
## warning actionable instead of just "something, somewhere, is white."
func _normalize_texture(tex: Texture2D, debug_name: String = "") -> Texture2D:
	var img := tex.get_image()
	if img == null:
		push_warning("Terrain3DTexturePool: %s has no accessible Image data, using pink placeholder" % debug_name)
		return _build_pink_texture()
	if img.get_size() == Vector2i(CANONICAL_SIZE, CANONICAL_SIZE) and img.get_format() == CANONICAL_FORMAT and img.has_mipmaps():
		return tex
	# Image.resize()/generate_mipmaps() both refuse to operate on compressed
	# formats directly (confirmed via a real error) -- decompress first,
	# resize/mipmap in an uncompressed format, then recompress to the
	# canonical target format.
	if img.is_compressed():
		if img.decompress() != OK:
			push_warning("Terrain3DTexturePool: %s failed to decompress, using pink placeholder" % debug_name)
			return _build_pink_texture()
	if img.get_size() != Vector2i(CANONICAL_SIZE, CANONICAL_SIZE):
		# resize()/convert() below both return void, not Error -- Godot gives
		# no per-call signal on failure for these two (confirmed against the
		# real Image class API, not assumed same as the Error-returning calls
		# around them). The final normalized-state check after compress()
		# below is what catches a bad outcome from either of these instead.
		img.resize(CANONICAL_SIZE, CANONICAL_SIZE, Image.INTERPOLATE_LANCZOS)
	# Drop any alpha channel before compressing -- Image.compress(COMPRESS_S3TC)
	# picks DXT1 vs DXT5 based on whether the source has non-opaque alpha
	# BYTES present, not visual appearance, so a real ground diffuse texture
	# that happens to carry stray non-255 alpha would otherwise silently
	# produce DXT5 and break the fixed CANONICAL_FORMAT guarantee this whole
	# normalization exists for.
	img.convert(Image.FORMAT_RGB8)
	# Real content sanity check, added while hunting a live-play report of
	# solid-white terrain patches: none of the format/size/mipmap validation
	# above can catch a texture that's technically well-formed but visually
	# blank/near-white (e.g. a bad source DDS, or a genuine decode issue this
	# pipeline doesn't otherwise detect). Sparse-samples a 16x16 grid (cheap,
	# no need to touch every one of 512*512 real pixels) and warns loudly,
	# naming the real texture path, on anything suspiciously bright and flat
	# -- ground diffuse textures are real, varied, natural material photos,
	# never uniformly near-white in real game data.
	var sample_sum := 0.0
	var sample_min := 1.0
	var sample_count := 0
	var step := maxi(img.get_width() / 16, 1)
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			var lum: float = img.get_pixel(x, y).get_luminance()
			sample_sum += lum
			sample_min = minf(sample_min, lum)
			sample_count += 1
	if sample_count > 0:
		var sample_avg := sample_sum / sample_count
		if sample_avg > 0.9 and sample_min > 0.8:
			push_warning("Terrain3DTexturePool: %s looks suspiciously blank/white (sampled avg luminance %.3f, min %.3f) -- likely the corrupt-texture source, not a real ground diffuse" % [debug_name, sample_avg, sample_min])
	if img.generate_mipmaps() != OK:
		push_warning("Terrain3DTexturePool: %s failed to generate mipmaps, using pink placeholder" % debug_name)
		return _build_pink_texture()
	if img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_GENERIC) != OK:
		push_warning("Terrain3DTexturePool: %s failed to compress, using pink placeholder" % debug_name)
		return _build_pink_texture()
	if img.get_format() != CANONICAL_FORMAT or img.get_size() != Vector2i(CANONICAL_SIZE, CANONICAL_SIZE) or not img.has_mipmaps():
		push_warning("Terrain3DTexturePool: %s normalized to unexpected state (format=%d size=%s mipmaps=%s), using pink placeholder" % [debug_name, img.get_format(), img.get_size(), img.has_mipmaps()])
		return _build_pink_texture()
	return ImageTexture.create_from_image(img)

## Shared by the pink fallback and the slot-31 NaN-collision guard below --
## both just need an unmissable, canonical-format placeholder that's never
## meant to be treated as real ground texture content.
## Real bug found via a live-play report right after _reserve_default_slot()
## started using this for real slot 0: full-saturation Color(1,0,1) has two
## channels pinned at maximum, and with real vertex-shading/bloom in play,
## enough real screen area covered by that (real per-vertex data currently
## unpainted regions are common -- most of a region outside its own resident
## cells, by design) blew out the whole view's exposure, reading as "solid
## white" rather than a recognizable, legible pink. `p_color` lets
## _reserve_default_slot() use a deliberately dimmer variant (still
## obviously synthetic, not a real ground texture) while genuine overflow
## keeps the original full-brightness pink -- that case is meant to be rare
## and attention-grabbing, this one is expected to cover real, large,
## ordinary "not streamed in yet" area and needs to stay legible instead of
## flooding the screen.
func _build_pink_texture(p_color: Color = Color(1.0, 0.0, 1.0)) -> ImageTexture:
	var pink_img := Image.create(CANONICAL_SIZE, CANONICAL_SIZE, false, Image.FORMAT_RGB8)
	pink_img.fill(p_color)
	pink_img.generate_mipmaps()
	pink_img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_GENERIC)
	return ImageTexture.create_from_image(pink_img)

func _ensure_pink_slot() -> int:
	if _pink_slot >= 0:
		return _pink_slot
	# Built directly at the canonical size/format -- no longer needs to query
	# an existing texture's own state, since every real texture entering this
	# pool is normalized to the same canonical target (see _normalize_texture()
	# above), so the pink fallback can just target it directly instead of
	# copying whatever happened to load first.
	var pink_asset := Terrain3DTextureAsset.new()
	pink_asset.set_name("__missing_texture_fallback")
	pink_asset.set_albedo_texture(_build_pink_texture())
	_terrain.assets.set_texture(TOTAL_SLOTS - 1, pink_asset)
	_pink_slot = _terrain.assets.get_texture_list().size() - 1
	return _pink_slot

## Real slot count currently assigned to distinct textures (excludes the pink
## fallback, whether or not it's been added yet) -- for diagnostics/tests, not
## used by the assignment logic itself.
func used_slot_count() -> int:
	return _slot_by_texture.size()
