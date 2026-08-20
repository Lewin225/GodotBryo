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
const RADIUS_LOAD_FULL := 4
const RADIUS_LOAD_DISTANT := 10

## Hysteresis: a resident tile isn't unloaded until it's past this larger
## radius, not the same threshold load uses -- otherwise a camera sitting
## almost exactly on the load boundary would thrash load/unload every
## check. Must stay > RADIUS_LOAD_DISTANT (the outer, not the full-detail,
## radius -- a distant-band tile still counts as resident and needs the
## same hysteresis margin a full-detail one does).
const RADIUS_UNLOAD := 13

## How often (seconds) to re-check the resident set against the camera's
## current position -- continuous, not boundary-cross-triggered, but a
## real-time interval rather than literally every single frame (streaming
## doesn't need sub-frame precision on when a check happens, only that gaps
## never open up before a tile has time to load in with margin).
const CHECK_INTERVAL_SEC := 0.1

## How many REFRs to place per frame before yielding, same meaning as
## CellLoader's own -- see CellStreamBuilder.
@export var objects_per_frame: int = 1

var esm: EsmReader
var resolver: GamebryoMeshResolver
var registry: GamebryoObjectRegistry
var _builder: CellStreamBuilder
var _pool: GamebryoResolverPool # phases/2/10-threaded-streaming-workers.md, step 4

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
var _pending: Dictionary = {} # Vector2i grid coord -> true, currently streaming in
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
	if _persistent_root != null:
		_persistent_root.free()
		_persistent_root = null
	if _persistent_batch != null:
		_persistent_batch.free_all()
		_persistent_batch = null
	_in_flight_count = 0

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

func _check_streaming() -> void:
	var center: Variant = _current_grid_coord()
	if center == null:
		return
	_current_cell_form_id_cache = _tile_cell_form_id(center) # cached here, on this already-throttled cycle, instead of get_current_cell_form_id() re-deriving it from a fresh find_exterior_cell() scan on every single call -- caught directly: that scan alone costs ~41ms (a full linear walk over WastelandNV's 185,720 child records), and game.gd's own _process() was calling get_current_cell_form_id() completely unthrottled, every frame, while active. Real, severe, unrelated to rendering at all -- explained the entire flat ~30fps ceiling this whole investigation was chasing.

	for dx in range(-RADIUS_LOAD_DISTANT, RADIUS_LOAD_DISTANT + 1):
		for dy in range(-RADIUS_LOAD_DISTANT, RADIUS_LOAD_DISTANT + 1):
			var coord := Vector2i(center.x + dx, center.y + dy)
			var desired_full: bool = absi(dx) <= RADIUS_LOAD_FULL and absi(dy) <= RADIUS_LOAD_FULL
			if not _resident.has(coord) and not _pending.has(coord):
				_start_tile_load(coord, desired_full)
			elif _resident.has(coord) and desired_full and not _resident_full_detail.get(coord, false):
				# phases/2/12-distant-object-lod.md, step 3: the camera moved
				# close enough that a tile streamed distant-only now needs
				# full detail -- re-stream it rather than leaving it stuck
				# showing only its VWD-flagged placements. Deliberately
				# one-directional: a full-detail tile is never downgraded
				# back to distant-only just because the camera moved away
				# again -- it stays fully resolved until RADIUS_UNLOAD evicts
				# it entirely, same hysteresis reasoning RADIUS_UNLOAD itself
				# already exists for (avoid thrashing near a boundary).
				_resident[coord].free()
				_resident.erase(coord)
				if _resident_batches.has(coord):
					_resident_batches[coord].free_all()
					_resident_batches.erase(coord)
				_resident_full_detail.erase(coord)
				_start_tile_load(coord, true)

	for coord in _resident.keys().duplicate():
		if absi(coord.x - center.x) > RADIUS_UNLOAD or absi(coord.y - center.y) > RADIUS_UNLOAD:
			_resident[coord].free()
			_resident.erase(coord)
			if _resident_batches.has(coord):
				_resident_batches[coord].free_all() # 2.9 -- explicit, Node.free() above doesn't reach RID-owned geometry
				_resident_batches.erase(coord)
			_resident_full_detail.erase(coord)

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
	tile_root.visible = false # hidden and physically inert until fully streamed in
	add_child(tile_root)

	var refr_root := Node3D.new()
	refr_root.name = "RefrRoot"
	refr_root.rotation_degrees.x = -90 # NIF/REFR Z-up -> Godot Y-up
	tile_root.add_child(refr_root)

	var terrain_root := Node3D.new()
	terrain_root.name = "TerrainRoot"
	tile_root.add_child(terrain_root)

	var _tt0 := Time.get_ticks_usec() # TEMP DIAGNOSTIC
	var terrain := _builder.build_terrain(cell_form_id)
	diagnostic_terrain_ms.append((Time.get_ticks_usec() - _tt0) / 1000.0) # TEMP DIAGNOSTIC
	if terrain != null:
		CellStreamBuilder.set_collision_disabled(terrain, true)
		terrain_root.add_child(terrain)

	# Deliberately NOT get_persistent_refs_for_cell() here -- persistent
	# refs are streamed exactly once into PersistentRoot by
	# _stream_persistent_root(), never per-tile (see this class's own doc
	# comment on why).
	var refs: Array = esm.get_cell_references(cell_form_id)

	# phases/2/09-direct-server-static-geometry.md: this tile's own RID batch
	# for non-interactive placements. Starts disabled -- the RID equivalent
	# of tile_root.visible=false/collision-disabled above, so nothing in the
	# batch is visible/collidable until the whole tile flips on atomically
	# below, same guarantee the Node-based half is already held to.
	var batch := DirectGeometryBatch.new()
	batch.init(self)
	batch.set_enabled(false)

	var _rt0 := Time.get_ticks_usec() # TEMP DIAGNOSTIC
	var results = await _resolve_refs_threaded(refs, my_generation, full_detail)
	diagnostic_resolve_wall_ms.append((Time.get_ticks_usec() - _rt0) / 1000.0) # TEMP DIAGNOSTIC

	_pending.erase(coord)
	_in_flight_count -= 1
	if results == null or my_generation != _generation:
		tile_root.free() # superseded/deactivated -- never was resident, safe to free
		batch.free_all() # RIDs aren't owned by tile_root, must be freed explicitly too
		_maybe_emit_settled()
		return

	var _t0 := Time.get_ticks_usec() # TEMP DIAGNOSTIC -- construct-step timing
	_construct_results(refr_root, results, batch)
	var _t1 := Time.get_ticks_usec()

	CellStreamBuilder.set_collision_disabled(tile_root, false)
	tile_root.visible = true
	batch.build() # creates the actual (batched, one-per-distinct-mesh) RenderingServer instances -- must happen before set_enabled() has anything to enable
	batch.set_enabled(true)
	var _t2 := Time.get_ticks_usec()
	diagnostic_construct_ms.append((_t1 - _t0) / 1000.0) # TEMP DIAGNOSTIC
	diagnostic_batch_build_ms.append((_t2 - _t1) / 1000.0) # TEMP DIAGNOSTIC
	diagnostic_refcounts.append(results.size()) # TEMP DIAGNOSTIC
	_resident[coord] = tile_root
	_resident_batches[coord] = batch
	_resident_full_detail[coord] = full_detail
	_maybe_emit_settled()

func _stream_persistent_root() -> void:
	var my_generation := _generation
	var root := Node3D.new()
	root.name = "PersistentRoot"
	root.visible = false
	add_child(root)

	var refr_root := Node3D.new()
	refr_root.name = "RefrRoot"
	refr_root.rotation_degrees.x = -90
	root.add_child(refr_root)

	var refs: Array = esm.get_persistent_refs_for_worldspace(_active_wrld_form_id)

	var batch := DirectGeometryBatch.new()
	batch.init(self)
	batch.set_enabled(false)

	_in_flight_count += 1
	var results = await _resolve_refs_threaded(refs, my_generation)

	_in_flight_count -= 1
	if results == null or my_generation != _generation:
		root.free() # deactivated mid-stream -- never was live, safe to free
		batch.free_all()
		_maybe_emit_settled()
		return

	_construct_results(refr_root, results, batch)

	CellStreamBuilder.set_collision_disabled(root, false)
	root.visible = true
	batch.build()
	batch.set_enabled(true)
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
func _construct_results(parent: Node3D, results: Array, batch: DirectGeometryBatch) -> void:
	for r in results:
		var node := registry.construct_from_resolved(r, batch)
		if node != null:
			parent.add_child(node)
			CellStreamBuilder.set_collision_disabled(node, true)

func _maybe_emit_settled() -> void:
	if _in_flight_count == 0:
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
