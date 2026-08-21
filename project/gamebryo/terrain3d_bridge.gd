class_name Terrain3DBridge
extends RefCounted

## phases/2/13-terrain3d-integration.md, implementation step 6: the real
## WorldStreamer-facing bridge to a single, shared, persistent Terrain3D node --
## importing one cell's real LAND data (height + BTXT/ATXT/VTXT-derived control map)
## at that cell's REAL world position, matching the existing REFR/GamebryoTerrainBuilder
## coordinate convention exactly (verified numerically, see
## test_terrain3d_bridge_placement.gd) so Terrain3D-rendered ground lines up with
## everything else already in the world -- not the simplified Vector3.ZERO placement
## the earlier single-cell spike tests used in isolation.
##
## Coordinate mapping (the one genuinely tricky part here): GamebryoTerrainBuilder
## places a cell's terrain root at world (grid_x*4096u2m, 0, -(grid_y*4096u2m)), with
## each local vertex at (col*spacing, height, -(row*spacing)) -- i.e. increasing
## Bethesda row/Y maps to DECREASING world Z. Terrain3D's own control/height images
## map image row directly to INCREASING world Z from the region's global_position
## (confirmed by reading Terrain3DData::get_pixel()'s source, not assumed -- see
## test_terrain3d_spike.gd's header comment). Reconciling the two needs a row flip
## (image_row = (GRID_SIZE-1) - row) PLUS a matching Z offset on global_position;
## worked out algebraically then confirmed against concrete grid_y=0/row=0/row=32
## cases before trusting it -- see cell_terrain3d_global_position()'s own comment.
## No flip is needed on X/col -- that axis already matches directly.

const CELL_SIZE_UNITS := 4096.0
const GAMEBRYO_UNITS_TO_METERS := 1.0 / 70.0
const GRID_SIZE := 33 # esm::kLandGridSize
const QUAD_HALF := 16
const QUAD_VERTS_PER_SIDE := 17
const VERTEX_SPACING := 128.0 * GAMEBRYO_UNITS_TO_METERS
## Real bug found in real play: region_size=64 (this doc's original choice, driven
## by the texture-budget research) doesn't actually fit the real WastelandNV
## worldspace at all -- Terrain3DData's region map is a hard-coded 32x32 grid
## (REGION_MAP_SIZE=32, terrain_3d_data.h), and WastelandNV's real grid extent
## (confirmed via a real full-worldspace scan, not assumed: grid_x/grid_y both span
## [-65, 64], 130 cells across) needs a region_size of at least 256 to fit inside
## that fixed grid -- 128 falls just short (computed region range [-17,16] vs the
## allowed [-16,15]). Real users hit this directly: cells far from the starting
## area failed every per-vertex write with "No active region found" (silently
## discarded region-creation for out-of-bounds locations), producing real,
## visible lag from the sheer volume of failed native calls/error logs, not real
## streaming work. 256 was also already the region_size phases/2/13's own
## real-data findings measured a worst-case texture need for (49 in a realistic
## 3x3-neighborhood) -- fits the current 31-usable-slot pool with real margin
## (14 spare) without needing to widen Terrain3D's own 5-bit texture-ID format
## (a separate, real, larger undertaking -- touches both this vendored addon's
## C++ AND its GLSL shaders in lockstep, deliberately not bundled with this fix).
const REGION_SIZE := 256

const QUADRANT_RANGES := [
	[0, QUAD_HALF, 0, QUAD_HALF], # BL
	[0, QUAD_HALF, QUAD_HALF, GRID_SIZE - 1], # BR
	[QUAD_HALF, GRID_SIZE - 1, 0, QUAD_HALF], # TL
	[QUAD_HALF, GRID_SIZE - 1, QUAD_HALF, GRID_SIZE - 1], # TR
]

var esm: EsmReader
var resolver: GamebryoMeshResolver
var texture_pool: Terrain3DTexturePool

## phases/2/14-native-terrain-texture-blend.md: real per-vertex authored normals
## (VNML), decode solved and verified numerically (128,000 real samples,
## avg 1.34 deg / max 53.5 deg divergence from a computed-from-heights normal --
## see _computed_normal()'s own comment for that formula, reused as the fallback
## here). Cheap A/B lever, not a design commitment either way -- when false, or
## when a given real cell simply has no VNML data (only 41,989/42,474 real LAND
## records do), every vertex falls back to _computed_normal() instead.
@export var import_authored_normals: bool = true

## Real debugging aid for the live white-terrain-patch investigation: when
## set to a real grid coordinate (e.g. Vector2i(-18, 0)), import_cell() prints
## exactly what real base/overlay pool slots it resolved for that ONE cell --
## cross-checkable directly against native/tools/land_cell_dump's own offline
## ESM dump of the same cell. Default (a coordinate no real WastelandNV cell
## can have) means "off"; deliberately not gated behind a separate bool so
## it's always obvious which cell (if any) is being watched.
var debug_dump_grid: Vector2i = Vector2i(999999, 999999)

func _init(esm_reader: EsmReader, mesh_resolver: GamebryoMeshResolver, pool: Terrain3DTexturePool) -> void:
	esm = esm_reader
	resolver = mesh_resolver
	texture_pool = pool

## Creates the one shared, persistent Terrain3D node -- called once by the owner
## (WorldStreamer), NOT per-cell. `region_size`/`vertex_spacing` set before adding
## to the tree; `data`/`assets` only become valid once added (Terrain3D::_initialize()
## runs on entering the tree -- confirmed by reading terrain_3d.cpp, see
## test_terrain3d_spike.gd's own header comment for the same finding).
##
## `debug_level` (Terrain3D.ERROR/INFO/DEBUG/EXTREME) is a STATIC property on the
## Terrain3D class itself (terrain_3d.h's own `static DebugLevel debug_level`),
## not per-instance -- setting it here on this one runtime-instantiated node
## (there's no Terrain3D node in the editor scene tree to configure this on
## directly, since it's built at runtime by activate(), not placed in
## game.tscn) affects every LOG() call across the whole addon for the rest of
## the session. Defaults back to the addon's own default (ERROR) -- the
## real solid-white-terrain-patch investigation
## ([[terrain3d_texture_normalize_bug]] in memory) already got what it needed
## from a DEBUG-level capture (ruled out shader-regen-on-new-texture as the
## cause); the next lead is a GDScript-side `push_warning` from
## `Terrain3DTexturePool._normalize_texture()`'s own content sanity check,
## which would otherwise be buried in this addon's own copious DEBUG-level
## noise. Pass `Terrain3D.DEBUG` explicitly again if the addon's own internals
## need tracing again later.
static func create_terrain(parent: Node, debug_level: Terrain3D.DebugLevel = Terrain3D.ERROR) -> Terrain3D:
	var terrain := Terrain3D.new()
	terrain.name = "Terrain3D"
	terrain.debug_level = debug_level
	terrain.vertex_spacing = VERTEX_SPACING
	parent.add_child(terrain)
	terrain.region_size = REGION_SIZE
	return terrain

## The real world position to pass as import_images()'s global_position for cell
## (grid_x, grid_y) -- see this file's header comment for the derivation. Simplifies
## to -((grid_y+1) * cell_size_m) on Z because 32 vertex-intervals * VERTEX_SPACING
## is exactly one cell width (32*128 Gamebryo units = 4096 = CELL_SIZE_UNITS) --
## confirmed by concrete check, not just algebra: at grid_y=0, row=0 (a cell's own
## south edge) must land at world Z=0 (matching GamebryoTerrainBuilder's own
## -(0*4096u2m) - 0*spacing = 0), and this formula reproduces exactly that.
static func cell_terrain3d_global_position(grid_x: int, grid_y: int) -> Vector3:
	var cell_size_m := CELL_SIZE_UNITS * GAMEBRYO_UNITS_TO_METERS
	return Vector3(grid_x * cell_size_m, 0.0, -((grid_y + 1) * cell_size_m))

static func _flipped_row(row: int) -> int:
	return (GRID_SIZE - 1) - row

## Imports one cell's real LAND data into `terrain` at its real world position.
## Returns false (no-op) if the cell has no LAND (interior cell, or a real exterior
## cell with no terrain data) -- a valid case, not an error, same as
## CellStreamBuilder.build_terrain()'s own null-return convention.
func import_cell(terrain: Terrain3D, cell_form_id: int) -> bool:
	var land: Dictionary = esm.get_land_data(cell_form_id)
	if land.is_empty():
		return false
	var grid: Dictionary = esm.get_exterior_cell_grid(cell_form_id)
	if grid.is_empty():
		return false
	var grid_x := int(grid.get("x", 0))
	var grid_y := int(grid.get("y", 0))
	var heights: PackedFloat32Array = land.get("heights", PackedFloat32Array())
	if heights.size() != GRID_SIZE * GRID_SIZE:
		return false

	var global_pos := cell_terrain3d_global_position(grid_x, grid_y)

	# --- Real finding: Terrain3DData.import_images() cannot be used for
	# incremental per-cell streaming into a shared Terrain3D node. It's a bulk,
	# region-ALIGNED, whole-region-REPLACING operation -- confirmed by reading
	# import_images()'s own slicing loop (terrain_3d_data.cpp): each slice is
	# written via `region->set_maps(images)`, and add_region()'s own log line
	# ("Overwriting existing region") confirms this replaces a region's entire
	# map wholesale, not a targeted blit into it. At region_size=64 (2 cells per
	# side), a cell's own 33-vertex span straddles an actual region boundary on
	# any axis where its grid coordinate is odd -- a second cell imported into
	# an already-populated shared region via import_images() would silently
	# wipe the first cell's data outside its own narrow slice. So this uses the
	# real per-pixel API instead (set_height()/set_control(), which DO write
	# into an existing region without disturbing the rest of it), after first
	# ensuring every region this cell's vertex range actually touches exists
	# (ensure_regions_for_cell() below) -- real, not assumed: verified via
	# test_terrain3d_bridge_placement.gd's cross-check against
	# GamebryoTerrainBuilder's own real placement, and its 2-real-adjacent-cell
	# edge-continuity check.
	var created_new_regions := ensure_regions_for_cell(terrain, grid_x, grid_y)

	# --- Real N=7-layer per-vertex texture write path ---
	# phases/2/14-native-terrain-texture-blend.md: real BTXT base (implicit
	# weight 1.0) + up to 6 real ATXT overlays, each alpha-blended over the
	# accumulated result by its own real per-vertex VTXT opacity in real
	# authored layer_index order. Replaces the old Terrain3D control-map
	# 2-texture "winner selection" entirely -- every real layer at every real
	# vertex is written, not just whichever one happened to be strongest.
	#
	# The real, uncapped worldspace-wide distinct-texture need (measured by
	# resolving every real BTXT/ATXT reference unconditionally, not just
	# winners -- phases/2/14's own verification) is 64, comfortably inside
	# the 126-slot pool budget, so every real layer for every quadrant is
	# resolved unconditionally here. No more lazy "only resolve if it wins
	# somewhere" -- that optimization existed only because the old
	# winner-take-all model made most candidate layers genuinely never render;
	# the real N=7 model renders every real layer that has nonzero opacity
	# anywhere, so lazy resolution would save nothing real.
	var quadrant_ltex: PackedInt64Array = land.get("quadrant_base_ltex", PackedInt64Array())
	var alpha_layers: Array = land.get("alpha_layers", [])

	var quadrant_layers := [[], [], [], []] # Array[{"opacity": PackedFloat32Array, "ltex_form_id": int, "layer_index": int}] per quadrant
	for layer in alpha_layers:
		var q: int = layer["quadrant"]
		if q < 0 or q >= 4:
			continue
		quadrant_layers[q].append(layer)
	for q in range(4):
		# Real authored stacking order -- ATXT's own layer_index field.
		quadrant_layers[q].sort_custom(func(a, b): return int(a["layer_index"]) < int(b["layer_index"]))

	var base_slot := [-1, -1, -1, -1]
	var overlay_slots := [[], [], [], []] # Array[int] (pool slot per real overlay, up to 6) per quadrant
	var overlay_layers := [[], [], [], []] # Array[Dictionary] (the layer dict each overlay_slots entry came from) per quadrant
	for q in range(4):
		var base_ltex := int(quadrant_ltex[q]) if q < quadrant_ltex.size() else 0
		base_slot[q] = _resolve_to_slot(base_ltex)
		var candidates: Array = quadrant_layers[q]
		if base_slot[q] < 0 and not candidates.is_empty():
			# Real BTXT=0 case: pick the aggregate-strongest raw layer as a
			# stable substitute base and remove it from the real overlay set
			# so it isn't written twice (as both base and an overlay).
			var best_i := -1
			var best_mass := -1.0
			for i in range(candidates.size()):
				var opacity: PackedFloat32Array = candidates[i]["opacity"]
				var mass := 0.0
				for v in opacity:
					mass += v
				if mass > best_mass:
					best_mass = mass
					best_i = i
			var fallback_slot := _resolve_to_slot(int(candidates[best_i]["ltex_form_id"]))
			if fallback_slot >= 0:
				base_slot[q] = fallback_slot
				candidates = candidates.duplicate()
				candidates.remove_at(best_i)
		# Real max is 6 (phases/2/13's own census + GECK wiki), clamp
		# defensively in case any other Gamebryo-family title's real data
		# ever exceeds that.
		for i in range(mini(candidates.size(), 6)):
			var slot := _resolve_to_slot(int(candidates[i]["ltex_form_id"]))
			overlay_slots[q].append(slot)
			overlay_layers[q].append(candidates[i])

	if Vector2i(grid_x, grid_y) == debug_dump_grid:
		print("Terrain3DBridge debug dump: cell (", grid_x, ",", grid_y, ")")
		for q in range(4):
			print("  quadrant ", q, ": base_slot=", base_slot[q], " overlay_slots=", overlay_slots[q],
					" overlay_layer_indices=", overlay_layers[q].map(func(l): return int(l["layer_index"])))

	# --- Real VCLR (vertex color) + VNML (authored normal) ---
	# phases/2/14-native-terrain-texture-blend.md: VCLR slots directly into
	# Terrain3D's own existing color_map (TYPE_COLOR) -- zero new cost, a real
	# free win from data this pipeline wasn't using. VNML is real per-vertex
	# authored normal data; falls back to _computed_normal() (same formula
	# this shader used to compute live, now baked in once at import) when
	# disabled or the real cell has no VNML.
	var vertex_colors: PackedByteArray = land.get("vertex_colors", PackedByteArray())
	var vertex_normals_raw: PackedByteArray = land.get("vertex_normals_raw", PackedByteArray())
	var has_vertex_colors := vertex_colors.size() >= GRID_SIZE * GRID_SIZE * 3
	var use_authored_normals := import_authored_normals and vertex_normals_raw.size() >= GRID_SIZE * GRID_SIZE * 3

	# --- Write every real vertex: height + VCLR/VNML + N=7 layer IDs/weights. ---
	for row in range(GRID_SIZE):
		for col in range(GRID_SIZE):
			var pos := vertex_world_position(global_pos, row, col)
			var idx := row * GRID_SIZE + col
			terrain.data.set_height(pos, heights[idx])

			if has_vertex_colors:
				var cr := float(vertex_colors[idx * 3 + 0]) / 255.0
				var cg := float(vertex_colors[idx * 3 + 1]) / 255.0
				var cb := float(vertex_colors[idx * 3 + 2]) / 255.0
				terrain.data.set_pixel(Terrain3DRegion.TYPE_COLOR, pos, Color(cr, cg, cb, 0.5))

			var world_normal: Vector3 = _decode_vnml_normal(vertex_normals_raw, idx) if use_authored_normals \
					else _computed_normal(heights, row, col)
			var enc := (world_normal + Vector3.ONE) * 0.5
			terrain.data.set_pixel(Terrain3DRegion.TYPE_NORMAL, pos, Color(enc.x, enc.y, enc.z, 1.0))

	for q in range(4):
		if base_slot[q] < 0:
			continue
		var r: Array = QUADRANT_RANGES[q]
		var row_start: int = r[0]
		var col_start: int = r[2]
		var slots: Array = overlay_slots[q]
		var layers: Array = overlay_layers[q]

		for row in range(r[0], r[1] + 1):
			for col in range(r[2], r[3] + 1):
				var local_index := (row - row_start) * QUAD_VERTS_PER_SIDE + (col - col_start)
				var ids := PackedInt32Array([base_slot[q], 0, 0, 0, 0, 0, 0])
				var weights := PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
				for i in range(slots.size()):
					if slots[i] < 0:
						continue
					var opacity: PackedFloat32Array = layers[i]["opacity"]
					var op: float = opacity[local_index] if local_index < opacity.size() else 0.0
					if op <= 0.0:
						continue
					ids[i + 1] = slots[i]
					weights[i] = clampf(op, 0.0, 1.0)
				var pos := vertex_world_position(global_pos, row, col)
				terrain.data.set_pixel(Terrain3DRegion.TYPE_TEX_ID_A, pos,
						Color(float(ids[0]) / 255.0, float(ids[1]) / 255.0, float(ids[2]) / 255.0, float(ids[3]) / 255.0))
				terrain.data.set_pixel(Terrain3DRegion.TYPE_TEX_ID_B, pos,
						Color(float(ids[4]) / 255.0, float(ids[5]) / 255.0, float(ids[6]) / 255.0, 0.0))
				terrain.data.set_pixel(Terrain3DRegion.TYPE_WEIGHT_A, pos,
						Color(weights[0], weights[1], weights[2], weights[3]))
				terrain.data.set_pixel(Terrain3DRegion.TYPE_WEIGHT_B, pos,
						Color(weights[4], weights[5], 0.0, 0.0))

	# Regenerates the GPU-side texture arrays/normals + the cached height range
	# this import's real changes need to actually render and cull correctly --
	# the numeric get_height()/get_control() checks in
	# test_terrain3d_bridge_placement.gd read region image data directly and
	# pass without any of this, but real rendering doesn't update without it,
	# and real culling doesn't work without the height range (see below).
	#
	# TWO separate real O(total-resident-regions) scaling bugs were found here
	# via real play profiling, not assumption -- both follow the identical
	# pattern: a Terrain3DData-level "recompute everything" call that's cheap
	# early in a session and increasingly expensive the longer play continues,
	# because neither one filters to just the region(s) THIS cell touched:
	#
	# 1. Terrain3DData::update_maps() (terrain_3d_data.cpp), called with no
	#    arguments: its real defaults are p_map_type=TYPE_MAX,
	#    p_all_regions=true -- which unconditionally clears
	#    _generated_height_maps/_generated_control_maps/_generated_color_maps
	#    and rebuilds ALL THREE GPU texture arrays from EVERY resident region,
	#    every single call (confirmed by reading the source's `default:` case
	#    under "Mark texture arrays dirty for rebuilding"). This was still
	#    real and dominant in a live profiler capture even AFTER fixing (2)
	#    below -- 27ms per import_cell() call, ~80ms across 3 calls in one
	#    frame, essentially unchanged, because this bug was untouched by that
	#    first fix.
	# 2. Terrain3DData::calc_height_range(true) (fixed first, still documented
	#    below for the full picture): recomputes EVERY resident region's
	#    height range from scratch, not just the touched one.
	#
	# Terrain3DData::update_master_height() (terrain_3d_data.h) exists to keep
	# the cached height range current as pixels are written, but is NEVER
	# actually called by set_height()/set_pixel() -- genuinely dead code in
	# the addon, confirmed by reading the source, not a usage mistake on our
	# side. Without a real recalculation, a freshly-created blank region's
	# height range stays near (0,0), and the mesh's own culling AABB (built
	# from that stale range instead of the real ~110-125m data) doesn't cover
	# where the real, shader-displaced geometry actually ends up -- this is
	# what caused the original angle-dependent culling bug this whole height-
	# range-recalculation path exists to fix.
	#
	# Both fixed the same way: mark ONLY the region(s) this cell's own vertex
	# range touches as needing work (Terrain3DRegion.set_edited(true) for the
	# texture-array path, Terrain3DRegion.calc_height_range() for the height-
	# range path -- real per-region work, correctly unavoidable), call the
	# Data-level functions in their CHEAP mode (update_maps(..., false, false)
	# takes the "only edited regions" incremental branch instead of a full
	# rebuild; calc_height_range(false) re-aggregates from each region's own
	# already-correct cached value instead of recomputing all of them), then
	# reset set_edited(false) -- update_maps()'s own incremental branch never
	# does this itself (confirmed by reading it), so without resetting here,
	# every previously-touched region would stay "edited" forever and the
	# incremental path would silently grow back into processing the entire
	# resident set again, defeating the fix over a long session.
	var touched_regions := _region_locations_for_cell(grid_x, grid_y)
	for loc in touched_regions:
		var region: Terrain3DRegion = terrain.data.get_region(loc)
		if region != null:
			region.set_edited(true)
			region.calc_height_range()
	if created_new_regions:
		# A brand new region grows the GPU texture ARRAYS themselves (one
		# layer per region) -- only a full rebuild (default args) can do that
		# correctly. Real, unavoidable cost for cells that expand into new
		# territory; the incremental path below is only safe once a region
		# already exists in the array.
		terrain.data.update_maps()
	else:
		terrain.data.update_maps(Terrain3DRegion.TYPE_MAX, false, false)
	terrain.data.calc_height_range(false)
	for loc in touched_regions:
		var region: Terrain3DRegion = terrain.data.get_region(loc)
		if region != null:
			region.set_edited(false)
	return true

## Real bug found via a 9x9-cell real-data verification pass (many cells resident
## at once, not just the 1-2-cell isolated tests): Terrain3DData::set_pixel()/
## get_pixel() (terrain_3d_data.cpp) compute their internal Vector2i pixel index by
## a raw C++ float-to-int CAST of `p_global_position / vertex_spacing` -- a
## TRUNCATION, not a round(). A world position meant to land exactly on integer
## pixel N can, after passing through VERTEX_SPACING's own multiply/divide chain
## (128.0/70.0 is not exactly representable in binary floating point), come out as
## N-0.0000001 due to ordinary accumulated rounding -- truncating to N-1 instead of
## N. Confirmed directly, not assumed: real (row,col) writes for cell (-14,-1)
## landed one column off (col=29's real value got overwritten by col=30's,
## verified by comparing the wrong stored value against every neighboring vertex's
## real expected height, not by guessing). This bias grows with distance from the
## world origin (more float precision loss at larger magnitudes), matching the
## real symptom: cells farther from (0,0) showed more affected vertices.
##
## Fixed with a small, consistently-signed epsilon nudge before the position ever
## reaches Terrain3D's own API -- real vertices are always >=1 full VERTEX_SPACING
## apart (~1.83m), so a nudge many orders of magnitude smaller can only ever push a
## "just barely on the wrong side" float back onto the intended integer pixel, and
## can never plausibly cross into a genuinely different vertex's own pixel.
const _PIXEL_INDEX_EPSILON := 0.001 # meters, ~0.05% of VERTEX_SPACING

## World position of vertex (row, col) given the cell's own cell_terrain3d_global_position()
## -- the row-flip is baked in here (see this file's header comment) so every caller
## (height writes, control writes, external cross-checks) uses one shared, single
## source of truth for the mapping instead of re-deriving it.
static func vertex_world_position(cell_global_pos: Vector3, row: int, col: int) -> Vector3:
	return cell_global_pos + Vector3(
			col * VERTEX_SPACING + _PIXEL_INDEX_EPSILON, 0.0,
			_flipped_row(row) * VERTEX_SPACING + _PIXEL_INDEX_EPSILON)

## Real VNML decode, verified numerically against 128,000 real samples
## (phases/2/14-native-terrain-texture-blend.md): SIGNED byte (not fopdoc's
## documented unsigned), Bethesda's own internal (X, Z, Y) file axis order.
## `raw` is the whole cell's flat PackedByteArray (3 bytes/vertex); `idx` is
## row*GRID_SIZE+col into it.
static func _decode_vnml_normal(raw: PackedByteArray, idx: int) -> Vector3:
	var bx: int = raw[idx * 3 + 0]
	var by: int = raw[idx * 3 + 1]
	var bz: int = raw[idx * 3 + 2]
	var cx := float(bx - 256 if bx >= 128 else bx) / 127.0
	var cy := float(by - 256 if by >= 128 else by) / 127.0
	var cz := float(bz - 256 if bz >= 128 else bz) / 127.0
	# world = (component[0], component[2], -component[1])
	var n := Vector3(cx, cz, -cy)
	return n.normalized() if n.length_squared() > 0.0001 else Vector3.UP

## Fallback normal for vertices/cells with no real VNML data (or the
## import_authored_normals toggle disabled) -- the same central-difference
## formula native/tools/vnml_check.cpp verified against real VNML data this
## same session (avg 1.34 deg divergence from the real authored normal), now
## reused as the actual real-play fallback instead of a one-off research
## check. Clamps at grid edges (one-sided difference) instead of wrapping or
## sampling outside the real 33x33 grid.
static func _computed_normal(heights: PackedFloat32Array, row: int, col: int) -> Vector3:
	var h_l := heights[row * GRID_SIZE + maxi(col - 1, 0)]
	var h_r := heights[row * GRID_SIZE + mini(col + 1, GRID_SIZE - 1)]
	var h_d := heights[maxi(row - 1, 0) * GRID_SIZE + col]
	var h_u := heights[mini(row + 1, GRID_SIZE - 1) * GRID_SIZE + col]
	var dx := Vector3(2.0 * VERTEX_SPACING, h_r - h_l, 0.0)
	var dz := Vector3(0.0, h_u - h_d, -2.0 * VERTEX_SPACING)
	return dx.cross(dz).normalized()

static func _floor_div(a: int, b: int) -> int:
	var q := a / b # GDScript int division truncates toward zero, not floor -- correct below
	var r := a % b
	if r != 0 and ((r < 0) != (b < 0)):
		q -= 1
	return q

## Ensures every Terrain3D region this cell's real vertex range touches exists,
## WITHOUT ever replacing an already-existing region (add_region_blank() always
## overwrites -- confirmed by reading add_region()'s own "Overwriting existing
## region" log path -- so this checks region_locations first). A cell can touch up
## to 4 regions (its own corners can straddle both axes' region boundaries at
## region_size=64 -- see this file's header comment).
##
## Deliberately computed in pure INTEGER grid math (grid_x/grid_y directly), NOT
## by taking get_region_location() of the cell's own float world-position corners
## -- a real bug found here: a cell edge that mathematically sits EXACTLY on a
## region boundary (e.g. world Z=0) can round to either side of that boundary
## depending on tiny floating-point differences between two expressions that are
## only equal in exact math (VERTEX_SPACING*(GRID_SIZE-1) vs
## CELL_SIZE_UNITS*GAMEBRYO_UNITS_TO_METERS -- mathematically identical since
## 32*128=4096, not bit-identical after float rounding). Computing which regions
## are POSSIBLE via integer grid_x/grid_y/REGION_SIZE math and creating all of
## them upfront makes the actual per-vertex float lookups robust regardless of
## which side of the boundary their own rounding lands on, since both candidate
## regions already exist either way.
## The (up to 4) distinct Terrain3D region locations cell (grid_x, grid_y)'s own
## vertex range touches -- pure integer grid math, see ensure_regions_for_cell()'s
## own doc comment for why (a real float-epsilon bug this replaced).
static func _region_locations_for_cell(grid_x: int, grid_y: int) -> Array[Vector2i]:
	var cell_span := GRID_SIZE - 1 # 32 vertex-intervals per cell side
	var x0 := grid_x * cell_span
	var x1 := x0 + cell_span
	var z0 := -grid_y * cell_span - cell_span
	var z1 := -grid_y * cell_span
	var region_x := [_floor_div(x0, REGION_SIZE), _floor_div(x1, REGION_SIZE)]
	var region_z := [_floor_div(z0, REGION_SIZE), _floor_div(z1, REGION_SIZE)]
	var out: Array[Vector2i] = []
	for rx in region_x:
		for rz in region_z:
			var loc := Vector2i(rx, rz)
			if not out.has(loc):
				out.append(loc)
	return out

## Returns true if at least one NEW region was created for this cell -- the
## caller (import_cell()) needs this: creating a region grows Terrain3D's own
## GPU texture ARRAYS (one layer per region), which can only be done via a full
## update_maps() rebuild, not the cheap per-region incremental path. Real bug
## found in real play from getting this wrong: using the incremental path
## unconditionally left every newly-created region's real data never actually
## reaching the GPU (Terrain3DData::update_maps()'s own "region map changed"
## handling sets its internal any_changed=true whenever add_region_blank() ran,
## which skips the incremental "only edited regions" branch -- but since the
## incremental call never marks the texture arrays dirty either, NEITHER path
## ends up rebuilding them for the new region). Terrain looked correct only for
## whatever streamed in before this bug was introduced, then invisible for
## everything after -- exactly matching "visible at startup, gone once more
## cells load."
static func ensure_regions_for_cell(terrain: Terrain3D, grid_x: int, grid_y: int) -> bool:
	var existing: Array = terrain.data.region_locations
	var created_any := false
	for loc in _region_locations_for_cell(grid_x, grid_y):
		if not existing.has(loc):
			terrain.data.add_region_blank(loc, false) # p_update=false -- batched update_maps() call is the caller's job (once per real streaming batch, not once per region)
			existing = terrain.data.region_locations
			created_any = true
	return created_any

## Real debugging aid, not (yet) a perf optimization: resolves every real
## `BTXT`/`ATXT` ground-texture reference for the whole worldspace into
## `texture_pool` UP FRONT, before any cell streams in, so the pool becomes a
## static, fully-populated set for the rest of the session instead of
## growing lazily as new cells get explored. Real motivation -- a live-play
## report of solid-white terrain patches (with bloom glowing around them,
## spreading to previously-fine cells, matching the addon's own
## `_generate_shader_code()`/`_update_shader()` firing on every genuinely-new
## texture added to the pool, visible directly in a real Terrain3D DEBUG-level
## log capture) -- isolates whether that's the actual cause: with a static
## pool, no new texture ever gets discovered mid-session, so if the
## corruption still happens, this rules out texture-pool growth as the cause
## entirely; if it stops, that confirms it.
##
## `grid_min`/`grid_max` default to WastelandNV's own real confirmed extent
## (both axes span [-65, 64] -- verified via a real full-worldspace scan,
## phases/2/14-native-terrain-texture-blend.md's own research). Pass explicit
## bounds for a different worldspace; this project has no general real
## worldspace-bounds parser yet (no `WRLD` `NAM0`/`NAM9`-equivalent read),
## just this hardcoded, confirmed-correct range for the one real worldspace
## currently in scope.
##
## Returns the real distinct-texture count registered (expected ~64, per the
## same real full-worldspace measurement this doc's design cited).
func prewarm_textures(wrld_form_id: int, grid_min: int = -65, grid_max: int = 64) -> int:
	var before := texture_pool.used_slot_count()
	for gx in range(grid_min, grid_max + 1):
		for gy in range(grid_min, grid_max + 1):
			var cell: Dictionary = esm.find_exterior_cell(wrld_form_id, gx, gy)
			if cell.is_empty():
				continue
			var land: Dictionary = esm.get_land_data(int(cell["form_id"]))
			if land.is_empty():
				continue
			var quadrant_ltex: PackedInt64Array = land.get("quadrant_base_ltex", PackedInt64Array())
			for ltex in quadrant_ltex:
				_resolve_to_slot(int(ltex))
			var alpha_layers: Array = land.get("alpha_layers", [])
			for layer in alpha_layers:
				_resolve_to_slot(int(layer["ltex_form_id"]))
	return texture_pool.used_slot_count() - before

func _resolve_to_slot(ltex_id: int) -> int:
	if ltex_id == 0:
		return -1
	var tex_path := esm.resolve_ltex_texture_path(ltex_id)
	if tex_path == "":
		return -1
	var tex := resolver.load_texture("textures\\" + tex_path)
	if tex == null:
		return -1
	return texture_pool.get_slot(tex, tex_path)
