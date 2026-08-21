class_name WorldStreamer
extends Node3D

## phases/2/08-world-cell-streaming.md: continuous adjacent-grid-cell
## streaming, parallel to (not replacing) CellLoader's single-active-cell
## orchestration. Purely position-reactive once active() -- see the task
## doc's "Purely position-reactive once active" section: it doesn't know
## why the active camera is wherever it is (a door teleport, a walk step,
## free-fly movement), only where. The only transition-facing API is
## activate(wrld_form_id)/deactivate() -- no "load cell X,Y" call, since the
## very next diff check picks up wherever the camera already is.
##
## Tracks the active CAMERA (get_viewport().get_camera_3d()), not the
## player body -- hardcoding to a player node would silently break
## free-fly/editor camera movement (the camera moves, nothing streams in).
##
## Uses CellStreamBuilder (shared with CellLoader) for the actual per-tile
## terrain+REFR streaming work, so that logic isn't duplicated between the
## single-active-cell and multi-tile-resident cases.
##
## Persistent refs (see EsmReader.get_persistent_refs_for_worldspace() --
## phases/2/07-runtime-cell-loader.md's "Known gap") get their own
## dedicated PersistentRoot node, built once per activate() and freed once
## on deactivate() -- never re-fetched per resident tile, which would
## duplicate the worldspace's entire persistent cell (quest markers, every
## exterior building's own entrance door, ...) once per currently-loaded
## tile.

signal streaming_settled

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"

## phases/2/12-distant-object-lod.md, step 3: two radii instead of one --
## every tile out to RADIUS_LOAD_DISTANT gets streamed in, but only tiles
## within RADIUS_LOAD_FULL resolve every placement; tiles in the wider band
## between the two only resolve VWD-flagged placements (the real per-REFR
## eligibility gate, see GamebryoObjectRegistry.resolve_placement()'s own
## doc comment), everything else skipped before it ever touches NIF/BSA.
## One streaming system, not two -- see that task doc's own "One widened
## streaming radius, not a second streaming system" section for why this
## shape was chosen over a separate wide/coarse pass. Real shape/size
## tuning against the actual Mojave worldspace is still
## phases/2/08-world-cell-streaming.md's own explicitly-deferred follow-on
## -- these are starting values to get the mechanism correct, not measured
## ones (though `RADIUS_LOAD_DISTANT`'s own real content density at this
## specific value IS measured, see phases/2/12's own survey).
##
## All four radii below are `float`, and every boundary check against them
## uses real (circular) distance via _within_radius(), not Chebyshev
## (square) distance -- caught directly from a real user-visible symptom
## ("multiple lines of cells appearing on one frame") while chasing a
## separate streaming-stutter fix: a Chebyshev check means crossing a
## single grid line brings an entire ring EDGE into range simultaneously
## (every dx/dy along that line, regardless of how far the corner of that
## edge actually is from the camera), not just the cells genuinely within
## range. `float` here isn't a precision fix (GDScript's `float` is already
## 64-bit, and grid deltas at these magnitudes are nowhere near where
## precision would matter) -- it's so a radius can be tuned to a real
## fractional distance instead of only whole grid steps, now that the
## check is a genuine distance comparison rather than a per-axis one.
const RADIUS_LOAD_FULL := 3.0
const RADIUS_LOAD_DISTANT := 20.0

## Hysteresis for the full/distant boundary, same reasoning as RADIUS_UNLOAD
## below but one tier in: a full-detail tile isn't downgraded back to
## distant-only until it's past this larger radius, not RADIUS_LOAD_FULL
## itself, so a camera sitting almost exactly on the full-detail boundary
## doesn't thrash upgrade/downgrade every check. Must stay strictly between
## RADIUS_LOAD_FULL and RADIUS_LOAD_DISTANT -- a full-detail tile that's
## fallen out of the full band still needs to become the distant-only
## variant, not skip straight past RADIUS_LOAD_DISTANT's own band entirely.
const RADIUS_UNLOAD_FULL := RADIUS_LOAD_FULL + 3.0

## Hysteresis: a resident tile isn't unloaded until it's past this larger
## radius, not the same threshold load uses -- otherwise a camera sitting
## almost exactly on the load boundary would thrash load/unload every
## check. Must stay > RADIUS_LOAD_DISTANT (the outer, not the full-detail,
## radius -- a distant-band tile still counts as resident and needs the
## same hysteresis margin a full-detail one does).
const RADIUS_UNLOAD := 23.0

## How often (seconds) to re-check the resident set against the camera's
## current position -- continuous, not boundary-cross-triggered, but a
## real-time interval rather than literally every single frame (streaming
## doesn't need sub-frame precision on when a check happens, only that gaps
## never open up before a tile has time to load in with margin).
const CHECK_INTERVAL_SEC := 0.1

## How many REFRs to construct (build Resources for + add_child()/
## batch.add_object()) per frame before yielding -- see _construct_results().
## Previously plumbed only to `_builder` (which WorldStreamer only ever
## calls build_terrain() on, never stream_refs()), so this field had no
## real effect on WorldStreamer's own behavior until this step actually
## used it for the construct loop. Default raised from 1 (a leftover from
## when this field did nothing here) to 20, matching CellLoader's own
## default -- at 1, a dense tile (real measured tiles run up to ~450
## placements) would take several seconds to finish visibly populating.
@export var objects_per_frame: int = 20

## How many NEW tile loads to actually START per frame -- see
## _process_load_queue(). Confirmed necessary via a real perf report, not
## hypothetical: _start_tile_load()'s own synchronous prefix
## (CellStreamBuilder.build_terrain(), ~75% of which is
## GamebryoTerrainBuilder's own collision generation) runs entirely before
## _stream_tile()'s first await point, so calling it many times back-to-back
## in the same _check_streaming() tick pays every one of those synchronous
## costs in one frame. That's exactly what happens when a whole new ring
## "edge" becomes needed at once -- crossing one grid line in a single axis
## brings in an entire new column/row, up to 2*RADIUS_LOAD_DISTANT+1 tiles,
## inherent to a square ring's own geometry (not a distance-calculation
## bug) -- the real report showed 57 tiles starting in one tick, 209ms of
## frame time, almost entirely build_terrain().
@export var tiles_per_frame: int = 3

## phases/2/12-distant-object-lod.md, step 8: the real, inspector-tunable
## crossover distance/margin -- threaded into both the Node-based path
## (resolver.set_lod_crossover(), step 6) and the RID-based path
## (batch.set_lod_crossover(), step 7) in _ready()/_stream_tile()/
## _stream_persistent_root() below, so there's exactly one place that
## actually decides this value at runtime, not two matching constants in
## two languages. Still a flat global placeholder, not the real
## per-category/size-proportional system enginedocs/lod.md describes -- see
## that task doc's own explicit scoping.
@export var lod_crossover_distance_m: float = 100.0
@export var lod_crossover_margin_m: float = 5.0

## phases/2/13-terrain3d-integration.md, implementation step 6: opt-in switch to
## the Terrain3D-based terrain path (Terrain3DBridge) instead of the existing,
## already-validated GamebryoTerrainBuilder path -- default false, per that doc's
## own "Coexistence / migration plan" (don't remove/risk the working path until
## Terrain3D's is validated in real play the same way 2.12 was). When true, a
## single shared, persistent Terrain3D node is created in activate() and each
## tile's terrain step calls Terrain3DBridge.import_cell() into it instead of
## CellStreamBuilder.build_terrain() -- timed into the same diagnostic_terrain_ms
## array for a direct, real before/after comparison (see _stream_tile()).
@export var use_terrain3d: bool = false

var esm: EsmReader
var resolver: GamebryoMeshResolver
var registry: GamebryoObjectRegistry
var _builder: CellStreamBuilder
var _pool: GamebryoResolverPool # phases/2/10-threaded-streaming-workers.md, step 4
var _terrain3d: Terrain3D # only non-null when use_terrain3d, created fresh per activate()
var _terrain3d_pool: Terrain3DTexturePool
var _terrain3d_bridge: Terrain3DBridge

var diagnostic_construct_ms: Array = [] # TEMP DIAGNOSTIC -- stutter investigation
var diagnostic_batch_build_ms: Array = [] # TEMP DIAGNOSTIC
var diagnostic_refcounts: Array = [] # TEMP DIAGNOSTIC
var diagnostic_terrain_ms: Array = [] # TEMP DIAGNOSTIC
var diagnostic_resolve_wall_ms: Array = [] # TEMP DIAGNOSTIC -- includes checkout-wait + task-poll wall time, not just the task's own CPU time
var diagnostic_find_exterior_cell_us := 0 # TEMP DIAGNOSTIC -- _start_tile_load()'s own find_exterior_cell() cost, main-thread, unthreaded

var _active_wrld_form_id: int = -1 # -1 == inactive
var _generation := 0 # bumped on every activate()/deactivate() -- invalidates stale in-flight tile streams
var _resident: Dictionary = {} # Vector2i grid coord -> built tile root Node3D
var _resident_batches: Dictionary = {} # Vector2i grid coord -> that tile's DirectGeometryBatch (2.9) -- kept in lockstep with _resident
var _resident_full_detail: Dictionary = {} # Vector2i grid coord -> bool, whether that resident tile was streamed with full_detail=true -- phases/2/12-distant-object-lod.md, step 3
var _pending: Dictionary = {} # Vector2i grid coord -> true, a _stream_tile() coroutine is actually running for it
var _queued: Dictionary = {} # Vector2i grid coord -> true, waiting in _load_queue for its turn to actually start -- see tiles_per_frame's own doc comment. A coord's lifecycle: queued -> pending -> resident
var _load_queue: Array = [] # Array of { "coord": Vector2i, "full_detail": bool }, FIFO, consumed by _process_load_queue()
var _load_queue_running := false # true while a _process_load_queue() coroutine is actively draining _load_queue -- avoids starting a second overlapping one
var _persistent_root: Node3D = null
var _persistent_batch: DirectGeometryBatch = null
var _in_flight_count := 0
var _check_timer := 0.0
var _current_cell_form_id_cache := 0 # updated only by _check_streaming()'s own throttled cycle -- see get_current_cell_form_id()'s doc comment for why this exists

func _ready() -> void:
	esm = EsmReader.new()
	if not esm.open(DATA_DIR + "FalloutNV.esm"):
		push_error("WorldStreamer: could not open FalloutNV.esm")
	resolver = GamebryoMeshResolver.new()
	resolver.set_lod_crossover(lod_crossover_distance_m, lod_crossover_margin_m) # phases/2/12-distant-object-lod.md, step 8 -- the Node-based construct path's own crossover (CONT/ACTI/FURN/DOOR VWD placements still build real Nodes even at runtime, see _construct_visual())
	registry = GamebryoObjectRegistry.new(resolver, esm)
	_builder = CellStreamBuilder.new(esm, resolver, registry, objects_per_frame)
	_pool = GamebryoResolverPool.new() # sized from OS.get_processor_count() -- see that class's own doc comment

## Starts (or retargets) continuous streaming for the given worldspace.
## Takes no position/cell -- the next check reacts to wherever the active
## camera already is. A no-op if already active for this exact worldspace.
func activate(wrld_form_id: int) -> void:
	if _active_wrld_form_id == wrld_form_id:
		return
	deactivate()
	_active_wrld_form_id = wrld_form_id
	_generation += 1
	if use_terrain3d:
		# Fresh per activate() -- a worldspace switch shouldn't carry stale
		# regions from the previous one (this is also why deactivate() frees it
		# rather than leaving it resident across an activate()/deactivate() pair
		# for a DIFFERENT worldspace; simple and correct, not yet the
		# region-residency-across-a-single-worldspace-session optimization the
		# design doc's "Streaming integration" section describes -- that's about
		# which regions stay loaded WITHIN one active worldspace as the camera
		# moves, a separate question from this per-worldspace lifecycle).
		_terrain3d = Terrain3DBridge.create_terrain(self)
		_terrain3d_pool = Terrain3DTexturePool.new(_terrain3d)
		_terrain3d_bridge = Terrain3DBridge.new(esm, resolver, _terrain3d_pool)
	_stream_persistent_root()
	_check_streaming() # immediate check, don't wait for the next timer tick

## Tears down every resident tile plus the PersistentRoot in one go, and
## stops streaming entirely until the next activate(). Safe to call when
## already inactive.
func deactivate() -> void:
	if _active_wrld_form_id == -1:
		return
	_active_wrld_form_id = -1
	_generation += 1 # invalidates any in-flight tile/persistent-root streams
	_current_cell_form_id_cache = 0
	for coord in _resident:
		_resident[coord].free()
		if _resident_batches.has(coord):
			_resident_batches[coord].free_all() # 2.9 -- RIDs aren't owned by the Node, must be freed explicitly, Node.free() above doesn't touch them
	_resident.clear()
	_resident_batches.clear()
	_resident_full_detail.clear()
	_pending.clear()
	_queued.clear()
	_load_queue.clear() # _load_queue_running's own coroutine (if any) checks _active_wrld_form_id and exits on its next iteration -- not force-cancelled here, same as any other in-flight await
	if _persistent_root != null:
		_persistent_root.free()
		_persistent_root = null
	if _persistent_batch != null:
		_persistent_batch.free_all()
		_persistent_batch = null
	_in_flight_count = 0
	if _terrain3d != null:
		_terrain3d.free()
		_terrain3d = null
		_terrain3d_pool = null
		_terrain3d_bridge = null

func is_active() -> bool:
	return _active_wrld_form_id != -1

func _process(delta: float) -> void:
	if _active_wrld_form_id == -1:
		return
	_check_timer -= delta
	if _check_timer > 0.0:
		return
	_check_timer = CHECK_INTERVAL_SEC
	_check_streaming()

func _active_camera() -> Camera3D:
	var vp := get_viewport()
	return vp.get_camera_3d() if vp != null else null

## The active camera's own grid coordinate, or null if there's currently no
## active camera to check (e.g. between scenes) -- a real, valid transient
## state, not an error.
func _current_grid_coord() -> Variant:
	var cam := _active_camera()
	if cam == null:
		return null
	var pos: Vector3 = cam.global_position
	var cell_size_m: float = CellStreamBuilder.CELL_SIZE_UNITS * CellStreamBuilder.GAMEBRYO_UNITS_TO_METERS
	# Inverse of CellStreamBuilder.build_terrain()'s own grid->world placement
	# (grid_x * cell_size_m, -(grid_y * cell_size_m)) -- floor(), not
	# truncation, so this stays correct for negative coordinates (a real,
	# common case -- Goodsprings' own tiles are at negative x).
	var gx := int(floor(pos.x / cell_size_m))
	var gy := int(floor(-pos.z / cell_size_m))
	return Vector2i(gx, gy)

## True if integer grid-coordinate delta (dx, dy) lies within `radius` of
## the origin, using real (circular) distance -- not Chebyshev/square
## distance (`absi(dx) <= radius and absi(dy) <= radius`), which is what
## every radius check here used before this. Compares squared distances
## (dx*dx + dy*dy vs radius*radius) rather than calling sqrt() -- cheaper,
## and there's no floating-point precision question to avoid in the first
## place at these magnitudes (grid deltas here max out in the tens, squared
## distances in the low thousands).
##
## The square-vs-circle distinction is the actual fix this exists for, not
## the float radius type: a Chebyshev check means crossing a single grid
## line brings an entire ring EDGE into range at once (every dx/dy along
## that line, regardless of how far the edge's own corner actually is from
## the camera) -- confirmed directly from a real user-visible symptom
## ("multiple lines of cells appearing on one frame") while chasing a
## separate streaming-stutter fix. Circular distance means only the cells
## genuinely within `radius` cross the boundary as the camera moves.
static func _within_radius(dx: int, dy: int, radius: float) -> bool:
	return dx * dx + dy * dy <= radius * radius

func _check_streaming() -> void:
	var center: Variant = _current_grid_coord()
	if center == null:
		return
	_current_cell_form_id_cache = _tile_cell_form_id(center) # cached here, on this already-throttled cycle, instead of get_current_cell_form_id() re-deriving it from a fresh find_exterior_cell() scan on every single call -- caught directly: that scan alone costs ~41ms (a full linear walk over WastelandNV's 185,720 child records), and game.gd's own _process() was calling get_current_cell_form_id() completely unthrottled, every frame, while active. Real, severe, unrelated to rendering at all -- explained the entire flat ~30fps ceiling this whole investigation was chasing.

	# The dx/dy loop bounds are still a square -- a cheap-to-enumerate
	# SUPERSET of the circular RADIUS_LOAD_DISTANT area, not the area itself
	# (there's no equivalently cheap way to enumerate a circle's integer
	# lattice points directly). ceili() so a fractional radius still gets a
	# bound that covers it.
	var bound := ceili(RADIUS_LOAD_DISTANT)
	for dx in range(-bound, bound + 1):
		for dy in range(-bound, bound + 1):
			if not _within_radius(dx, dy, RADIUS_LOAD_DISTANT):
				continue # inside the square bound but outside the real circular radius
			var coord := Vector2i(center.x + dx, center.y + dy)
			var desired_full: bool = _within_radius(dx, dy, RADIUS_LOAD_FULL)
			if not _resident.has(coord) and not _pending.has(coord) and not _queued.has(coord):
				_enqueue_tile_load(coord, desired_full)
			elif _resident.has(coord) and desired_full and not _resident_full_detail.get(coord, false):
				# phases/2/12-distant-object-lod.md, step 3: the camera moved
				# close enough that a tile streamed distant-only now needs
				# full detail -- re-stream it rather than leaving it stuck
				# showing only its VWD-flagged placements.
				_resident[coord].free()
				_resident.erase(coord)
				if _resident_batches.has(coord):
					_resident_batches[coord].free_all()
					_resident_batches.erase(coord)
				_resident_full_detail.erase(coord)
				_enqueue_tile_load(coord, true)
			elif _resident.has(coord) and _resident_full_detail.get(coord, false) and not _within_radius(dx, dy, RADIUS_UNLOAD_FULL):
				# The reverse case -- a full-detail tile the camera has since
				# moved away from, past RADIUS_UNLOAD_FULL but still within
				# RADIUS_LOAD_DISTANT (so still resident, just no longer near
				# enough to warrant every placement). RADIUS_UNLOAD itself is a
				# much wider hysteresis margin than RADIUS_LOAD_FULL (13 vs 1),
				# so without this a tile the camera had merely passed through
				# would stay fully resolved -- every placement, not just
				# VWD-flagged ones -- for as long as it remained resident at
				# all, not just while the camera was actually near it. Gated on
				# RADIUS_UNLOAD_FULL rather than RADIUS_LOAD_FULL itself for the
				# same thrash-avoidance reason the upgrade case above and
				# RADIUS_UNLOAD below each already use their own hysteresis
				# margin for.
				_resident[coord].free()
				_resident.erase(coord)
				if _resident_batches.has(coord):
					_resident_batches[coord].free_all()
					_resident_batches.erase(coord)
				_resident_full_detail.erase(coord)
				_enqueue_tile_load(coord, false)

	for coord in _resident.keys().duplicate():
		if not _within_radius(coord.x - center.x, coord.y - center.y, RADIUS_UNLOAD):
			_resident[coord].free()
			_resident.erase(coord)
			if _resident_batches.has(coord):
				_resident_batches[coord].free_all() # 2.9 -- explicit, Node.free() above doesn't reach RID-owned geometry
				_resident_batches.erase(coord)
			_resident_full_detail.erase(coord)

## Queues `coord` for a throttled start instead of calling _start_tile_load()
## immediately -- see tiles_per_frame's own doc comment for why. Marks
## `coord` as spoken-for (_queued) right away so repeated _check_streaming()
## ticks (every CHECK_INTERVAL_SEC, likely several before this coord's turn
## comes up) don't enqueue it again.
func _enqueue_tile_load(coord: Vector2i, full_detail: bool) -> void:
	_queued[coord] = true
	_load_queue.append({ "coord": coord, "full_detail": full_detail })
	if not _load_queue_running:
		_load_queue_running = true
		_process_load_queue()

## Drains _load_queue, starting up to tiles_per_frame tiles before yielding
## a frame -- this is what actually bounds how many synchronous
## build_terrain() calls happen in any one frame, regardless of how many
## coords _check_streaming() enqueues at once (up to a whole ring edge, see
## tiles_per_frame's own doc comment).
##
## The leading `await` here is load-bearing, not decorative -- caught
## directly via a real perf report showing the throttle doing nothing at
## all (55 calls each to _enqueue_tile_load/_process_load_queue/
## _start_tile_load, all equal, all in one frame). _check_streaming()'s own
## loop calls _enqueue_tile_load() once per coord, synchronously, with no
## await of its own -- so without this, the very first enqueued coord would
## immediately spin up a runner that finds exactly one item in the queue
## (the rest of the ring hasn't been enqueued yet), drains it, finds the
## queue empty again, and exits -- resetting _load_queue_running to false
## before _check_streaming()'s loop even reaches its next iteration. Every
## subsequent enqueue then sees "not running" and repeats the same
## immediate single-item drain, never actually queueing anything.
## Yielding one frame before ever touching _load_queue guarantees
## _check_streaming()'s entire synchronous loop (it has no awaits of its
## own) has already finished enqueueing everything for this tick by the
## time this coroutine looks at the queue for real.
func _process_load_queue() -> void:
	await get_tree().process_frame
	while not _load_queue.is_empty():
		if _active_wrld_form_id == -1:
			break # deactivated mid-drain -- deactivate() already cleared _load_queue/_queued itself
		var started := 0
		while started < tiles_per_frame and not _load_queue.is_empty():
			var entry: Dictionary = _load_queue.pop_front()
			var coord: Vector2i = entry["coord"]
			_queued.erase(coord)
			# Re-check before starting, not just trust the queue snapshot --
			# a queued coord can still have become resident/pending by the
			# time its turn comes up (e.g. the SAME _check_streaming() tick
			# that enqueued it also evicted-and-re-enqueued it again via the
			# upgrade/downgrade branches before this coroutine ever ran).
			if not _resident.has(coord) and not _pending.has(coord):
				_start_tile_load(coord, entry["full_detail"])
			started += 1
		if not _load_queue.is_empty():
			await get_tree().process_frame
	_load_queue_running = false

func _start_tile_load(coord: Vector2i, full_detail: bool = true) -> void:
	var _d0 := Time.get_ticks_usec() # TEMP DIAGNOSTIC
	var cell: Dictionary = esm.find_exterior_cell(_active_wrld_form_id, coord.x, coord.y)
	diagnostic_find_exterior_cell_us += Time.get_ticks_usec() - _d0 # TEMP DIAGNOSTIC
	if cell.is_empty():
		return # no cell at this grid coordinate -- a real case at a worldspace's edge, not an error
	_pending[coord] = true
	_in_flight_count += 1
	_stream_tile(int(cell["form_id"]), coord, _generation, full_detail)

func _stream_tile(cell_form_id: int, coord: Vector2i, my_generation: int, full_detail: bool) -> void:
	var tile_root := Node3D.new()
	tile_root.name = "Tile_%d_%d" % [coord.x, coord.y]
	add_child(tile_root)

	var refr_root := Node3D.new()
	refr_root.name = "RefrRoot"
	refr_root.rotation_degrees.x = -90 # NIF/REFR Z-up -> Godot Y-up
	tile_root.add_child(refr_root)

	var terrain_root := Node3D.new()
	terrain_root.name = "TerrainRoot"
	tile_root.add_child(terrain_root)

	var _tt0 := Time.get_ticks_usec() # TEMP DIAGNOSTIC
	if use_terrain3d:
		# phases/2/13-terrain3d-integration.md, implementation step 6: same
		# diagnostic_terrain_ms array as the GamebryoTerrainBuilder path below,
		# for a direct real before/after comparison -- import_cell() writes
		# directly into the shared _terrain3d node (real per-vertex
		# set_height()/set_control() calls, see terrain3d_bridge.gd), nothing to
		# parent under terrain_root (there's exactly one Terrain3D node for the
		# whole worldspace, not one per tile).
		_terrain3d_bridge.import_cell(_terrain3d, cell_form_id)
		diagnostic_terrain_ms.append((Time.get_ticks_usec() - _tt0) / 1000.0) # TEMP DIAGNOSTIC
	else:
		var terrain := _builder.build_terrain(cell_form_id)
		diagnostic_terrain_ms.append((Time.get_ticks_usec() - _tt0) / 1000.0) # TEMP DIAGNOSTIC
		if terrain != null:
			CellStreamBuilder.set_collision_disabled(terrain, false) # visible+collidable immediately -- see _construct_results()'s own doc comment on progressive reveal
			terrain_root.add_child(terrain)

	# Deliberately NOT get_persistent_refs_for_cell() here -- persistent
	# refs are streamed exactly once into PersistentRoot by
	# _stream_persistent_root(), never per-tile (see this class's own doc
	# comment on why).
	var refs: Array = esm.get_cell_references(cell_form_id)

	# phases/2/09-direct-server-static-geometry.md: this tile's own RID batch
	# for non-interactive placements. Starts disabled -- deliberately still
	# atomic (unlike the Node-based tier below, phases/2/12's own progressive-
	# reveal change) since DirectGeometryBatch groups MultiMesh instances by
	# mesh identity and allocates each one once at a known final size; the
	# expensive per-object work (mesh/material Resource construction) still
	# happens spread across frames inside the construct loop below, only the
	# final reveal (confirmed cheap, diagnostic_batch_build_ms) stays bundled.
	var batch := DirectGeometryBatch.new()
	batch.init(self)
	batch.set_lod_crossover(lod_crossover_distance_m, lod_crossover_margin_m) # phases/2/12-distant-object-lod.md, step 8 -- the real, single-sourced exported value (was a duplicated GDScript/C++ constant pair in step 7)
	batch.set_enabled(false)

	var _rt0 := Time.get_ticks_usec() # TEMP DIAGNOSTIC
	var results = await _resolve_refs_threaded(refs, my_generation, full_detail)
	diagnostic_resolve_wall_ms.append((Time.get_ticks_usec() - _rt0) / 1000.0) # TEMP DIAGNOSTIC

	if results == null or my_generation != _generation:
		_pending.erase(coord)
		_in_flight_count -= 1
		tile_root.free() # superseded/deactivated -- never was resident, safe to free
		batch.free_all() # RIDs aren't owned by tile_root, must be freed explicitly too
		_maybe_emit_settled()
		return

	# `coord` deliberately stays in _pending through the whole (possibly
	# multi-frame) construct phase below, not just the resolve phase above --
	# _check_streaming() only skips starting a new load for a coord that's
	# resident OR pending; erasing it early (as this used to, right after
	# resolve) would open a window where a coord is in neither dict and a
	# duplicate load could start for the same tile.
	var construct_result := await _construct_results(refr_root, results, batch, my_generation)
	diagnostic_construct_ms.append(construct_result["active_ms"]) # TEMP DIAGNOSTIC -- active construct time only, excludes the awaited frame gaps between batches

	if not construct_result["ok"]:
		_pending.erase(coord)
		_in_flight_count -= 1
		tile_root.free() # frees every partially-added child too
		batch.free_all() # covers whatever add_object() calls already ran (see DirectGeometryBatch::free_all())
		_maybe_emit_settled()
		return

	var _t2 := Time.get_ticks_usec() # TEMP DIAGNOSTIC
	batch.build() # creates the actual (batched, one-per-distinct-mesh) RenderingServer instances -- must happen before set_enabled() has anything to enable
	batch.set_enabled(true)
	diagnostic_batch_build_ms.append((Time.get_ticks_usec() - _t2) / 1000.0) # TEMP DIAGNOSTIC
	diagnostic_refcounts.append(results.size()) # TEMP DIAGNOSTIC
	_pending.erase(coord)
	_in_flight_count -= 1
	_resident[coord] = tile_root
	_resident_batches[coord] = batch
	_resident_full_detail[coord] = full_detail
	_maybe_emit_settled()

func _stream_persistent_root() -> void:
	var my_generation := _generation
	var root := Node3D.new()
	root.name = "PersistentRoot"
	add_child(root)

	var refr_root := Node3D.new()
	refr_root.name = "RefrRoot"
	refr_root.rotation_degrees.x = -90
	root.add_child(refr_root)

	var refs: Array = esm.get_persistent_refs_for_worldspace(_active_wrld_form_id)

	var batch := DirectGeometryBatch.new()
	batch.init(self)
	batch.set_lod_crossover(lod_crossover_distance_m, lod_crossover_margin_m) # phases/2/12-distant-object-lod.md, step 8 -- the real, single-sourced exported value (was a duplicated GDScript/C++ constant pair in step 7)
	batch.set_enabled(false)

	_in_flight_count += 1
	var results = await _resolve_refs_threaded(refs, my_generation)

	if results == null or my_generation != _generation:
		_in_flight_count -= 1
		root.free() # deactivated mid-stream -- never was live, safe to free
		batch.free_all()
		_maybe_emit_settled()
		return

	var construct_result := await _construct_results(refr_root, results, batch, my_generation)
	if not construct_result["ok"]:
		_in_flight_count -= 1
		root.free()
		batch.free_all()
		_maybe_emit_settled()
		return

	batch.build()
	batch.set_enabled(true)
	_in_flight_count -= 1
	_persistent_root = root
	_persistent_batch = batch
	_maybe_emit_settled()

## phases/2/10-threaded-streaming-workers.md, step 4: checks out a pool
## context, dispatches `refs`' resolve work (GamebryoObjectRegistry.
## resolve_tile(), see that class's own doc comment -- pure data in, pure
## data out, no Node/RenderingServer/PhysicsServer3D touched) to a
## WorkerThreadPool task, and polls once per frame until it completes --
## shared by _stream_tile() and _stream_persistent_root() so the checkout/
## dispatch/poll/checkin dance exists in exactly one place.
##
## Returns the resolved results Array, or null if `my_generation` went
## stale before a task ever got dispatched (still waiting on a free pool
## slot -- the caller never started real work, nothing to wait for). A task
## that HAS been dispatched is always waited on to completion regardless of
## cancellation -- WorkerThreadPool requires every task be waited for so it
## can release its own internal resources, and there's no way to kill a
## running task -- its result is simply discarded by the caller (checked via
## the SAME my_generation comparison after this returns) if it's gone stale
## by the time it finishes.
func _resolve_refs_threaded(refs: Array, my_generation: int, full_detail: bool = true) -> Variant:
	var ctx: GamebryoResolveContext = _pool.checkout()
	while ctx == null:
		if my_generation != _generation:
			return null # never dispatched -- nothing to wait for
		await get_tree().process_frame
		ctx = _pool.checkout()

	var holder := [null]
	var task_id: int = WorkerThreadPool.add_task(func(): holder[0] = registry.resolve_tile(refs, ctx, full_detail))
	while not WorkerThreadPool.is_task_completed(task_id):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task_id) # mandatory even for a discarded result -- releases the task's internal resources
	_pool.checkin(ctx)

	if my_generation != _generation:
		return null
	return holder[0]

## The main-thread-only "commit" step: builds a real Node (or feeds `batch`
## for the structural-fallback case) from each already-resolved result and
## adds it under `parent`. No I/O left by this point -- see
## GamebryoObjectRegistry.construct_from_resolved()'s own doc comment.
##
## Spread across multiple frames (`objects_per_frame` results per frame
## before yielding), not built synchronously in one frame -- the mesh/
## collision Resource construction inside construct_from_resolved() is the
## real expensive per-object work (confirmed via diagnostic_construct_ms's
## own real outliers, up to ~18ms for one dense tile before this change),
## and yielding periodically divides that cost across frames instead of
## paying it all at once in a single frame. Node-based results become
## visible (and collidable) immediately as they're add_child()'d -- no more
## hidden-until-the-whole-tile-is-done -- per explicit user direction:
## meshes appearing one by one reads as less jarring than an entire tile
## popping in at once. `batch`'s own RID-batched results are NOT revealed
## progressively -- the caller still only flips them visible via
## batch.build()/set_enabled(true) once this whole function returns
## successfully; DirectGeometryBatch groups MultiMesh instances by mesh
## identity and allocates each once at a known final size, so it can't grow
## incrementally the way a Node tree can. The expensive part (mesh/material
## building, inside construct_from_resolved()) still happens spread across
## frames either way; only the cheap final RenderingServer reveal itself
## (confirmed ~0.01-0.03ms average, diagnostic_batch_build_ms) stays bundled.
##
## Returns { "ok": bool, "active_ms": float }: `ok` is false if
## `my_generation` went stale partway through (checked once per yield, not
## per object -- checking more often than a real yield boundary can't
## change the answer) -- the caller must discard/free everything already
## added, same as an equivalent pre-construct cancellation. `active_ms` is
## the real active construct time only, excluding the awaited frame gaps
## between batches -- what diagnostic_construct_ms actually wants to know,
## not this function's own wall-clock span (which would include however
## many real frames it happened to take).
func _construct_results(parent: Node3D, results: Array, batch: DirectGeometryBatch, my_generation: int) -> Dictionary:
	var per_frame: int = max(objects_per_frame, 1)
	var active_us := 0
	var seg_start := Time.get_ticks_usec()
	var i := 0
	for r in results:
		var node := registry.construct_from_resolved(r, batch)
		if node != null:
			parent.add_child(node)
			CellStreamBuilder.set_collision_disabled(node, false)
		i += 1
		if i % per_frame == 0:
			active_us += Time.get_ticks_usec() - seg_start
			await get_tree().process_frame
			if my_generation != _generation:
				return { "ok": false, "active_ms": active_us / 1000.0 }
			seg_start = Time.get_ticks_usec()
	active_us += Time.get_ticks_usec() - seg_start
	return { "ok": true, "active_ms": active_us / 1000.0 }

## Also checks _load_queue/_load_queue_running, not just _in_flight_count --
## a real race otherwise: _in_flight_count only counts tiles that have
## actually STARTED (_start_tile_load()), so every currently-in-flight tile
## could finish (hitting _in_flight_count == 0) in the gap between two
## _process_load_queue() drain batches, while tiles are still sitting
## queued waiting their turn under tiles_per_frame's own throttle -- caught
## by reasoning through the coroutine interleaving, not observed as an
## actual test failure, but real enough not to leave unguarded.
func _maybe_emit_settled() -> void:
	if _in_flight_count == 0 and _load_queue.is_empty() and not _load_queue_running:
		streaming_settled.emit()

## Combined REFR placement data for every currently resident tile plus the
## persistent root -- same Dictionary shape as CellLoader's own
## get_current_refs(), for a caller wanting to look up a specific placed
## REFR (e.g. an interact raycast's own collider) by EditorID/FormID across
## everything actually streamed in right now.
func get_current_refs() -> Array:
	var out: Array = []
	for coord in _resident:
		out.append_array(esm.get_cell_references(_tile_cell_form_id(coord)))
	if _persistent_root != null:
		out.append_array(esm.get_persistent_refs_for_worldspace(_active_wrld_form_id))
	return out

func _tile_cell_form_id(coord: Vector2i) -> int:
	var cell: Dictionary = esm.find_exterior_cell(_active_wrld_form_id, coord.x, coord.y)
	return int(cell.get("form_id", 0))

## The CELL FormID for whichever grid tile the active camera is currently
## in -- for a caller wanting to display/query "where is the player right
## now" (e.g. game.gd's cell HUD). 0 if inactive, there's no active camera,
## or there's genuinely no cell at that grid coordinate (a worldspace edge).
##
## Returns a value cached on _check_streaming()'s own throttled cycle
## (CHECK_INTERVAL_SEC) rather than re-deriving it here on every call.
## Caught directly, not hypothetical: find_exterior_cell() is a full linear
## scan over the worldspace's child records (185,720 for WastelandNV) and
## costs ~41ms per call -- game.gd's own _process() was calling this
## function completely unthrottled, every single frame, while active. That
## single bug alone accounted for the entire flat ~30fps ceiling this
## session's whole rendering-performance investigation was chasing --
## camera-direction/window-size/node-count/draw-call independence all
## immediately made sense once this was found, since none of those things
## have anything to do with a per-frame ESM file scan.
func get_current_cell_form_id() -> int:
	if _active_wrld_form_id == -1:
		return 0
	return _current_cell_form_id_cache
