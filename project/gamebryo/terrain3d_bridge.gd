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
const REGION_SIZE := 64 # phases/2/13-terrain3d-integration.md's chosen value

const QUADRANT_RANGES := [
	[0, QUAD_HALF, 0, QUAD_HALF], # BL
	[0, QUAD_HALF, QUAD_HALF, GRID_SIZE - 1], # BR
	[QUAD_HALF, GRID_SIZE - 1, 0, QUAD_HALF], # TL
	[QUAD_HALF, GRID_SIZE - 1, QUAD_HALF, GRID_SIZE - 1], # TR
]

var esm: EsmReader
var resolver: GamebryoMeshResolver
var texture_pool: Terrain3DTexturePool

func _init(esm_reader: EsmReader, mesh_resolver: GamebryoMeshResolver, pool: Terrain3DTexturePool) -> void:
	esm = esm_reader
	resolver = mesh_resolver
	texture_pool = pool

## Creates the one shared, persistent Terrain3D node -- called once by the owner
## (WorldStreamer), NOT per-cell. `region_size`/`vertex_spacing` set before adding
## to the tree; `data`/`assets` only become valid once added (Terrain3D::_initialize()
## runs on entering the tree -- confirmed by reading terrain_3d.cpp, see
## test_terrain3d_spike.gd's own header comment for the same finding).
static func create_terrain(parent: Node) -> Terrain3D:
	var terrain := Terrain3D.new()
	terrain.name = "Terrain3D"
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
	ensure_regions_for_cell(terrain, grid_x, grid_y)

	# --- Per-quadrant BTXT base + opacity-priority ATXT/VTXT overlay reduction
	# (same algorithm as test_terrain3d_multilayer_paint.gd, reused here for real
	# streaming instead of an isolated test cell) ---
	var quadrant_ltex: PackedInt64Array = land.get("quadrant_base_ltex", PackedInt64Array())
	var alpha_layers: Array = land.get("alpha_layers", [])
	var quadrant_overlay := [null, null, null, null]
	var quadrant_overlay_mass := [0.0, 0.0, 0.0, 0.0]
	for layer in alpha_layers:
		var q: int = layer["quadrant"]
		if q < 0 or q >= 4:
			continue
		var opacity: PackedFloat32Array = layer["opacity"]
		var mass := 0.0
		for v in opacity:
			mass += v
		if mass > quadrant_overlay_mass[q]:
			quadrant_overlay_mass[q] = mass
			quadrant_overlay[q] = layer

	var base_slot := [-1, -1, -1, -1]
	var overlay_slot := [-1, -1, -1, -1]
	for q in range(4):
		var base_ltex := int(quadrant_ltex[q]) if q < quadrant_ltex.size() else 0
		base_slot[q] = _resolve_to_slot(base_ltex)
		if quadrant_overlay[q] != null:
			overlay_slot[q] = _resolve_to_slot(int(quadrant_overlay[q]["ltex_form_id"]))

	# --- Write every real vertex directly: height always, control only within
	# whichever quadrant(s) actually have a resolved base texture. ---
	for row in range(GRID_SIZE):
		for col in range(GRID_SIZE):
			var pos := vertex_world_position(global_pos, row, col)
			terrain.data.set_height(pos, heights[row * GRID_SIZE + col])

	for q in range(4):
		if base_slot[q] < 0:
			continue
		var r: Array = QUADRANT_RANGES[q]
		var row_start: int = r[0]
		var col_start: int = r[2]
		var overlay: int = overlay_slot[q]
		var opacity: PackedFloat32Array = quadrant_overlay[q]["opacity"] if quadrant_overlay[q] != null else PackedFloat32Array()
		for row in range(r[0], r[1] + 1):
			for col in range(r[2], r[3] + 1):
				var blend := 0.0
				if overlay >= 0:
					var local_index := (row - row_start) * QUAD_VERTS_PER_SIDE + (col - col_start)
					blend = opacity[local_index] if local_index < opacity.size() else 0.0
				var blend_u8 := int(roundf(clampf(blend, 0.0, 1.0) * 255.0))
				var control_value: int = Terrain3DUtil.enc_base(base_slot[q]) | Terrain3DUtil.enc_overlay(maxi(overlay, 0)) | Terrain3DUtil.enc_blend(blend_u8)
				var pos := vertex_world_position(global_pos, row, col)
				terrain.data.set_control(pos, control_value)

	# Regenerates the GPU-side texture arrays/normals this import's real changes
	# need to actually render -- the numeric get_height()/get_control() checks in
	# test_terrain3d_bridge_placement.gd read region image data directly and pass
	# without this, but real rendering doesn't update without it. Called once per
	# cell here (simplest, definitely-correct starting point) rather than batched
	# across multiple tiles-per-frame -- real per-call cost, and whether batching
	# it is worth the complexity, is exactly the open profiling question
	# phases/2/13-terrain3d-integration.md's implementation step 6 still has.
	terrain.data.update_maps()

	# Real bug found in real play (angle-dependent culling -- terrain only
	# visible looking down more than ~40 degrees, distant terrain less affected):
	# Terrain3DData::update_master_height() (terrain_3d_data.h) exists to keep
	# the terrain's own cached height range current as pixels are written, but
	# is NEVER actually called by set_height()/set_pixel() -- confirmed by
	# reading the source, not assumed; it's genuinely dead code in the addon.
	# A freshly-created blank region's height range defaults near 0, and
	# without this call it never gets recalculated from our real writes, so the
	# mesh's own culling AABB (built from that stale [0,0]-ish range instead of
	# the real ~110-125m data) doesn't cover where the real, shader-displaced
	# geometry actually ends up -- exactly explains angle-dependent culling.
	# calc_height_range(true) forces a real recalculation from the actual pixel
	# data -- but a real, separate bug found in real play (a real half-second
	# 30fps stall reappearing, the same class of stutter 2.9-2.12 already fixed
	# once for the old terrain path): Terrain3DData::calc_height_range(true)
	# (terrain_3d_data.cpp) recomputes EVERY resident region's full height
	# range from scratch on EVERY call, not just the region(s) this one cell
	# touched -- confirmed by reading its source, a plain loop over
	# `_region_locations` with no filtering. Calling it unconditionally per
	# cell means cost grows with TOTAL resident regions, not O(1) per cell --
	# fine early in a session, increasingly expensive the longer play
	# continues and more of the map has streamed in, matching exactly what was
	# reported (a real profiler capture showing 75ms across 3 import_cell()
	# calls in one frame). Fixed by only recalculating the region(s) this
	# cell's own vertex range actually touched (Terrain3DRegion.calc_height_range(),
	# real per-region work, unavoidable and correct), then a cheap
	# non-recursive Terrain3DData.calc_height_range(false) to re-aggregate the
	# master range from each region's own (now correctly cached) range instead
	# of recomputing all of them.
	for loc in _region_locations_for_cell(grid_x, grid_y):
		var region: Terrain3DRegion = terrain.data.get_region(loc)
		if region != null:
			region.calc_height_range()
	terrain.data.calc_height_range(false)
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

static func ensure_regions_for_cell(terrain: Terrain3D, grid_x: int, grid_y: int) -> void:
	var existing: Array = terrain.data.region_locations
	for loc in _region_locations_for_cell(grid_x, grid_y):
		if not existing.has(loc):
			terrain.data.add_region_blank(loc, false) # p_update=false -- batched update_maps() call is the caller's job (once per real streaming batch, not once per region)
			existing = terrain.data.region_locations

func _resolve_to_slot(ltex_id: int) -> int:
	if ltex_id == 0:
		return -1
	var tex_path := esm.resolve_ltex_texture_path(ltex_id)
	if tex_path == "":
		return -1
	var tex := resolver.load_texture("textures\\" + tex_path)
	if tex == null:
		return -1
	return texture_pool.get_slot(tex)
