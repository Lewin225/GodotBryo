class_name WorldStreamer
extends Node3D

const GameDataConfigScript := preload("res://game_data_config.gd")

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
## Terrain is independently owned by the sibling TerrainStreamer. This class
## streams placed objects only; its sole terrain interaction is a priority hint.
##
## Persistent refs (see EsmReader.get_persistent_refs_for_worldspace() --
## phases/2/07-runtime-cell-loader.md's "Known gap") get their own
## dedicated PersistentRoot node, built once per activate() and freed once
## on deactivate() -- never re-fetched per resident tile, which would
## duplicate the worldspace's entire persistent cell (quest markers, every
## exterior building's own entrance door, ...) once per currently-loaded
## tile.

signal streaming_settled

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
const RADIUS_LOAD_FULL := 5.0
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
## Applied by WorldStreamer's main-thread object construction loop.
@export var objects_per_frame: int = 20

## How many NEW tile loads to actually START per frame -- see
## _process_load_queue(). Confirmed necessary via a real perf report, not
## hypothetical: _start_tile_load() has synchronous lookup/setup work before
## _stream_tile()'s first await point. A whole new ring
## "edge" becomes needed at once -- crossing one grid line in a single axis
## brings in an entire new column/row, up to 2*RADIUS_LOAD_DISTANT+1 tiles,
## inherent to a square ring's own geometry (not a distance-calculation
## bug) -- the real report showed 57 tiles starting in one tick.
@export var tiles_per_frame: int = 3

## Issue #6: opt-in, concise main-thread stall trace. The normal streaming
## diagnostic prints were too noisy to leave on during ordinary play; this
## records only the stage immediately before/after work that can block frame
## presentation. Toggle it from Debug Tools -> World Streaming before
## reproducing a suspected freeze.
@export var freeze_trace_enabled: bool = false

var esm: EsmReader
var resolver: GamebryoMeshResolver
var registry: GamebryoObjectRegistry
var _pool: GamebryoResolverPool # phases/2/10-threaded-streaming-workers.md, step 4
var terrain_streamer: TerrainStreamer

var diagnostic_construct_ms: Array = [] # TEMP DIAGNOSTIC -- stutter investigation
var diagnostic_batch_build_ms: Array = [] # TEMP DIAGNOSTIC
var diagnostic_refcounts: Array = [] # TEMP DIAGNOSTIC
var diagnostic_resolve_wall_ms: Array = [] # TEMP DIAGNOSTIC -- includes checkout-wait + task-poll wall time, not just the task's own CPU time
var diagnostic_find_exterior_cell_us := 0 # TEMP DIAGNOSTIC -- _start_tile_load()'s own find_exterior_cell() cost, main-thread, unthreaded

func _freeze_trace(coord: Vector2i, stage: String, detail: String = "") -> void:
	if not freeze_trace_enabled:
		return
	print("WorldStreamer freeze trace: tile %s | %s%s" % [coord, stage, " | " + detail if not detail.is_empty() else ""])

## True while object streaming is paused -- resident tiles and batches stay
## intact, just hidden and
## physically inert, instead of being freed the way deactivate() does. Exists
## for the interior-transition case: door-triggered CellLoader.load_cell()
## calls used to deactivate() WorldStreamer entirely, meaning every real door
## back out to the same exterior spot paid the full activate() cost again --
## every resident tile re-streamed. See
## set_paused()'s own comment for what "hidden and physically inert" actually
## requires -- Node visibility alone does NOT cover this project's own
## RID-based DirectGeometryBatch geometry or PhysicsServer bodies.
var _paused := false
var _active_wrld_form_id: int = -1 # -1 == inactive
var _generation := 0 # bumped on every activate()/deactivate() -- invalidates stale in-flight tile streams
var _resident: Dictionary = {} # Vector2i grid coord -> built tile root Node3D
var _resident_batches: Dictionary = {} # Vector2i grid coord -> that tile's DirectGeometryBatch (2.9) -- kept in lockstep with _resident
var _resident_full_detail: Dictionary = {} # Vector2i grid coord -> bool, whether that resident tile was streamed with full_detail=true -- phases/2/12-distant-object-lod.md, step 3
var _pending: Dictionary = {} # Vector2i grid coord -> true, a _stream_tile() coroutine is actually running for it
var _queued: Dictionary = {} # Vector2i grid coord -> true, waiting in _load_queue for its turn to actually start -- see tiles_per_frame's own doc comment. A coord's lifecycle: queued -> pending -> resident
var _load_queue: Array = [] # Array of { "coord": Vector2i, "full_detail": bool }, FIFO, consumed by _process_load_queue()
var _load_queue_running := false # true while a _process_load_queue() coroutine is actively draining _load_queue -- avoids starting a second overlapping one
## Vector2i grid coord -> true, confirmed (via _start_tile_load()'s own
## esm.find_exterior_cell() lookup) to have no real cell in the CURRENTLY
## active worldspace. Real, common, and permanent for a given
## (worldspace, coord) pair -- a worldspace's grid footprint doesn't change
## at runtime -- so once confirmed empty, _check_streaming() should never
## enqueue that coord again for as long as this worldspace stays active.
## Without this, _check_streaming() re-enqueues the SAME out-of-bounds
## coordinates forever (nothing ever marks them resident/pending, so its
## own "not resident and not pending and not queued" guard never excludes
## them once they've cycled back out of the queue) -- pure wasted work for
## any worldspace with an edge within RADIUS_LOAD_DISTANT, and the dominant
## case (not the edge case) for a worldspace smaller than the streaming
## radius itself, like Freeside's own (see this file's own softlock
## write-up in memory: freeside-softlock-streaming-settled). Cleared in
## deactivate() -- a coord empty in one worldspace says nothing about the
## next one activate() switches to.
var _no_cell_cache: Dictionary = {}
var _persistent_root: Node3D = null
var _persistent_batch: DirectGeometryBatch = null
var _in_flight_count := 0
var _check_timer := 0.0
var _current_cell_form_id_cache := 0 # updated only by _check_streaming()'s own throttled cycle -- see get_current_cell_form_id()'s doc comment for why this exists

func _ready() -> void:
	var data_dir := GameDataSettings.get_data_dir()
	if esm == null or resolver == null:
		esm = EsmReader.new()
		if not esm.open(data_dir + GameDataConfigScript.ESM_FILE):
			push_error("WorldStreamer fallback could not open FalloutNV.esm")
		resolver = GamebryoMeshResolver.new(data_dir)
	# GodotBryoSettings (issue #56) is the single source of truth -- threaded
	# into both the Node-based path (resolver, here) and the RID-based path
	# (batch, in _stream_tile()/_stream_persistent_root() below).
	resolver.set_lod_crossover(GodotBryoSettings.get_lod0_crossover_distance_raw(), GodotBryoSettings.get_lod0_crossover_margin_raw(), GodotBryoSettings.get_lod1_max_range_raw()) # phases/2/12-distant-object-lod.md, step 8 -- the Node-based construct path's own crossover (CONT/ACTI/FURN/DOOR VWD placements still build real Nodes even at runtime, see _construct_visual())
	resolver.set_distant_lod_range(GodotBryoSettings.get_distant_lod_near_cutoff_raw(), GodotBryoSettings.get_distant_lod_near_margin_raw()) # issue #56
	registry = GamebryoObjectRegistry.new(resolver, esm)
	_pool = GamebryoResolverPool.new(-1, data_dir) # sized from OS.get_processor_count() -- see that class's own doc comment

func configure(esm_reader: EsmReader, mesh_resolver: GamebryoMeshResolver) -> void:
	esm = esm_reader
	resolver = mesh_resolver

func set_terrain_streamer(owner: TerrainStreamer) -> void:
	terrain_streamer = owner

## Starts (or retargets) continuous streaming for the given worldspace.
## Takes no position/cell -- the next check reacts to wherever the active
## camera already is. A no-op if already active for this exact worldspace.
func activate(wrld_form_id: int) -> void:
	if _active_wrld_form_id == wrld_form_id:
		set_paused(false) # resumes cleanly if this worldspace was left paused (see set_paused()) -- a real no-op if it wasn't
		return
	deactivate()
	_active_wrld_form_id = wrld_form_id
	_generation += 1
	_stream_persistent_root()
	_check_streaming() # immediate check, don't wait for the next timer tick

## Tears down every resident tile plus the PersistentRoot in one go, and
## stops streaming entirely until the next activate(). Safe to call when
## already inactive.
func deactivate() -> void:
	if _active_wrld_form_id == -1:
		return
	_active_wrld_form_id = -1
	_paused = false # a fresh activate() later must start unpaused/visible -- everything below is about to be freed anyway, this just keeps is_paused()/visible from reporting stale state after a full teardown
	visible = true
	_generation += 1 # invalidates any in-flight tile/persistent-root streams
	_current_cell_form_id_cache = 0
	_no_cell_cache.clear() # per-worldspace -- a coord empty here says nothing about whichever worldspace activates next
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

func is_active() -> bool:
	return _active_wrld_form_id != -1

## True while streaming is paused for THIS worldspace -- see set_paused().
## False when fully inactive too (is_active() covers that case for a caller
## wanting to distinguish "inactive" from "active but paused").
func is_paused() -> bool:
	return _paused

## Freezes (or resumes) streaming without freeing anything -- see _paused's
## own doc comment for why this exists instead of deactivate()/activate().
## A no-op if already in the requested state, or if fully inactive (nothing
## to pause/resume).
##
## Pausing must reach three separate layers, not just the Node tree's own
## `visible` flag, each for its own real reason (worked out from how each
## piece of resident geometry is actually implemented, not assumed covered
## by one flag):
##  1. `visible = false` on this node IS enough for every ordinary Node-based
##     visual (MeshInstance3D/VisualInstance3D) -- Godot's own visibility
##     inheritance toggles the underlying RenderingServer instance RID
##     automatically as an ancestor's `visible` changes.
##  2. It does NOT reach `DirectGeometryBatch` (phases/2/09) -- that manages
##     raw RenderingServer MultiMesh RIDs directly, with no Node3D wrapping
##     them to inherit visibility from at all. Needs its own set_enabled(false).
##  3. It does NOT reach ANY PhysicsServer3D body regardless of whether it is
##     Node-based or not -- collision stays live in the physics world
##     independent of node visibility/process state. Node-based REFR
##     collision (StaticBody3D/CollisionShape3D under each tile/persistent
##     root) needs CellStreamBuilder.set_collision_disabled().
## Without all three, resuming would look fine visually while the player
## could still be blocked by (or standing on) invisible exterior collision
## while indoors -- a real, silent gameplay bug, not just a rendering glitch.
func set_paused(p: bool) -> void:
	if p == _paused or _active_wrld_form_id == -1:
		return
	_paused = p
	visible = not p
	for coord in _resident:
		CellStreamBuilder.set_collision_disabled(_resident[coord], p)
		if _resident_batches.has(coord):
			_resident_batches[coord].set_enabled(not p)
	if _persistent_root != null:
		CellStreamBuilder.set_collision_disabled(_persistent_root, p)
	if _persistent_batch != null:
		_persistent_batch.set_enabled(not p)
	if not p:
		# Resuming: re-check residency once immediately (matches activate()'s
		# own "don't wait for the next timer tick" reasoning) -- nothing
		# should actually need streaming since no world-space position moved
		# while paused, but a caller (game.gd's _do_exterior_transition())
		# awaits streaming_settled unconditionally on every exterior door,
		# same as the fresh-activate() case, so this must still be the thing
		# that fires it back on immediately when there's genuinely nothing to do.
		_check_streaming()
		# Real bug found in real play: set_paused(false) is called SYNCHRONOUSLY
		# from activate() (see its own "already active" branch), which itself is
		# called synchronously (not awaited) by game.gd's _do_exterior_transition()
		# BEFORE it reaches its own `await world_streamer.streaming_settled` line.
		# When _check_streaming() above finds nothing actually needs streaming
		# (the common case here -- the resident set from before pausing is still
		# valid, nothing moved in world-space while indoors), calling
		# _maybe_emit_settled() directly emits the signal immediately, with zero
		# listeners connected yet -- the emission is simply lost, and the
		# caller's await never wakes up, leaving the player frozen forever.
		# Every OTHER _maybe_emit_settled() call site is safe because it runs
		# inside a coroutine that has already crossed a real await (a queued
		# frame, a WorkerThreadPool poll) by the time it fires -- this is the
		# only synchronous path to it. call_deferred() pushes the check to the
		# end of the current frame, after _do_exterior_transition()'s await has
		# already registered its listener.
		call_deferred("_maybe_emit_settled")

func _process(delta: float) -> void:
	if _active_wrld_form_id == -1 or _paused:
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
	# Inverse of the established exterior grid-to-world placement
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
			if terrain_streamer != null:
				terrain_streamer.request_terrain_priority(coord)
			if _no_cell_cache.has(coord):
				continue # confirmed no real cell here for this worldspace -- see _no_cell_cache's own doc comment
			var desired_full: bool = _within_radius(dx, dy, RADIUS_LOAD_FULL)
			if not _resident.has(coord) and not _pending.has(coord) and not _queued.has(coord):
				_enqueue_tile_load(coord, desired_full)
			elif _resident.has(coord) and desired_full and not _resident_full_detail.get(coord, false):
				# phases/2/12-distant-object-lod.md, step 3: the camera moved
				# close enough that a tile streamed distant-only now needs
				# full detail -- re-stream it rather than leaving it stuck
				# showing only its VWD-flagged placements.
				_freeze_trace(coord, "upgrade eviction begin", "dx=%d dy=%d" % [dx, dy])
				var eviction_start_us: int = Time.get_ticks_usec()
				_resident[coord].free()
				_resident.erase(coord)
				if _resident_batches.has(coord):
					_resident_batches[coord].free_all()
					_resident_batches.erase(coord)
				_resident_full_detail.erase(coord)
				_freeze_trace(coord, "upgrade eviction end", "%.2f ms" % ((Time.get_ticks_usec() - eviction_start_us) / 1000.0))
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
## a frame -- this bounds synchronous object setup regardless of how many
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
	# Softlock fix (real bug, found via a real freeze entering Freeside):
	# this coroutine is the only place that can make all three of
	# _maybe_emit_settled()'s conditions true WITHOUT itself calling it --
	# every other place that can (every return path in _stream_tile()/
	# _stream_persistent_root()) already does. Without this, once every real
	# coordinate near the player is resident and only no-longer-relevant
	# out-of-bounds coordinates remain (see _no_cell_cache below -- a small/
	# enclosed worldspace like Freeside's own, where the streaming radius
	# overhangs its actual grid footprint in every direction, hits this on
	# essentially every entry), nothing is left to ever re-check settlement,
	# and a caller awaiting streaming_settled (game.gd's
	# _do_exterior_transition(), which froze the player for exactly this
	# signal) hangs forever.
	_maybe_emit_settled()

func _start_tile_load(coord: Vector2i, full_detail: bool = true) -> void:
	var _d0 := Time.get_ticks_usec() # TEMP DIAGNOSTIC
	var cell: Dictionary = esm.find_exterior_cell(_active_wrld_form_id, coord.x, coord.y)
	diagnostic_find_exterior_cell_us += Time.get_ticks_usec() - _d0 # TEMP DIAGNOSTIC
	if cell.is_empty():
		_no_cell_cache[coord] = true # a real case at a worldspace's edge, not an error -- see _no_cell_cache's own doc comment for why this is remembered rather than re-attempted every check
		return
	_pending[coord] = true
	_in_flight_count += 1
	_stream_tile(int(cell["form_id"]), coord, _generation, full_detail)

func _stream_tile(cell_form_id: int, coord: Vector2i, my_generation: int, full_detail: bool) -> void:
	_freeze_trace(coord, "tile stream begin", "cell=0x%X full_detail=%s" % [cell_form_id, full_detail])
	var tile_root := Node3D.new()
	tile_root.name = "Tile_%d_%d" % [coord.x, coord.y]
	add_child(tile_root)

	var refr_root := Node3D.new()
	refr_root.name = "RefrRoot"
	refr_root.rotation_degrees.x = -90 # NIF/REFR Z-up -> Godot Y-up
	tile_root.add_child(refr_root)

	# Deliberately NOT get_persistent_refs_for_cell() here -- persistent
	# refs are streamed exactly once into PersistentRoot by
	# _stream_persistent_root(), never per-tile (see this class's own doc
	# comment on why).
	var refs: Array = esm.get_cell_references(cell_form_id)
	_freeze_trace(coord, "references read", "%d refs" % refs.size())

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
	batch.set_lod_crossover(GodotBryoSettings.get_lod0_crossover_distance_raw(), GodotBryoSettings.get_lod0_crossover_margin_raw(), GodotBryoSettings.get_lod1_max_range_raw()) # phases/2/12-distant-object-lod.md, step 8 -- GodotBryoSettings (issue #56) is the single source of truth
	batch.set_enabled(false)

	var _rt0 := Time.get_ticks_usec() # TEMP DIAGNOSTIC
	_freeze_trace(coord, "worker resolve begin")
	var results = await _resolve_refs_threaded(refs, my_generation, full_detail)
	diagnostic_resolve_wall_ms.append((Time.get_ticks_usec() - _rt0) / 1000.0) # TEMP DIAGNOSTIC
	_freeze_trace(coord, "worker resolve end", "%.2f ms" % ((Time.get_ticks_usec() - _rt0) / 1000.0))

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
	_freeze_trace(coord, "main-thread construct begin", "%d results" % results.size())
	var construct_result := await _construct_results(refr_root, results, batch, my_generation, coord)
	diagnostic_construct_ms.append(construct_result["active_ms"]) # TEMP DIAGNOSTIC -- active construct time only, excludes the awaited frame gaps between batches
	_freeze_trace(coord, "main-thread construct end", "%.2f active ms" % float(construct_result["active_ms"]))

	if not construct_result["ok"]:
		_pending.erase(coord)
		_in_flight_count -= 1
		tile_root.free() # frees every partially-added child too
		batch.free_all() # covers whatever add_object() calls already ran (see DirectGeometryBatch::free_all())
		_maybe_emit_settled()
		return

	var _t2 := Time.get_ticks_usec() # TEMP DIAGNOSTIC
	_freeze_trace(coord, "batch build begin")
	batch.build() # creates the actual (batched, one-per-distinct-mesh) RenderingServer instances -- must happen before set_enabled() has anything to enable
	batch.set_enabled(true)
	diagnostic_batch_build_ms.append((Time.get_ticks_usec() - _t2) / 1000.0) # TEMP DIAGNOSTIC
	_freeze_trace(coord, "batch build end", "%.2f ms" % ((Time.get_ticks_usec() - _t2) / 1000.0))
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

	# Issue #56: Bethesda's baked distant/world-object LOD tiles
	# (meshes\landscape\lod\<world>\...) are placed as ordinary persistent
	# STAT refs. The terrain-only tiles (any tier) are fully redundant now
	# that terrain renders via the Terrain3D clipmap -- drop them before
	# they ever reach the resolver/BSA-load step. See
	# GamebryoMeshResolver.is_terrain_only_lod_tile_path()'s own doc
	# comment for the confirmed-exhaustive reasoning.
	var filtered_refs: Array = []
	for ref in refs:
		if GamebryoMeshResolver.is_terrain_only_lod_tile_path(String(ref.get("model", ""))):
			continue
		filtered_refs.append(ref)
	refs = filtered_refs

	var batch := DirectGeometryBatch.new()
	batch.init(self)
	batch.set_lod_crossover(GodotBryoSettings.get_lod0_crossover_distance_raw(), GodotBryoSettings.get_lod0_crossover_margin_raw(), GodotBryoSettings.get_lod1_max_range_raw()) # phases/2/12-distant-object-lod.md, step 8 -- GodotBryoSettings (issue #56) is the single source of truth
	batch.set_distant_lod_range(GodotBryoSettings.get_distant_lod_near_cutoff_raw(), GodotBryoSettings.get_distant_lod_near_margin_raw()) # issue #56 -- only PersistentRoot's batch actually contains distant/skyline LOD tiles

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
func _construct_results(parent: Node3D, results: Array, batch: DirectGeometryBatch, my_generation: int, trace_coord: Vector2i = Vector2i(999999, 999999)) -> Dictionary:
	var per_frame: int = max(objects_per_frame, 1)
	var active_us := 0
	var seg_start := Time.get_ticks_usec()
	var i := 0
	for r in results:
		if freeze_trace_enabled and trace_coord.x != 999999:
			var result: Dictionary = r
			var placement: Dictionary = result.get("placement", {})
			_freeze_trace(trace_coord, "construct item begin", "%d/%d kind=%s type=%s base=0x%X" % [i + 1, results.size(), result.get("kind", ""), placement.get("base_type", ""), int(placement.get("base_form_id", 0))])
		var node := registry.construct_from_resolved(r, batch)
		if freeze_trace_enabled and trace_coord.x != 999999:
			_freeze_trace(trace_coord, "construct item end", "%d/%d" % [i + 1, results.size()])
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
