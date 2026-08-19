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

## Radius (in grid cells, each axis independently) kept loaded around the
## active camera's own tile -- a (2*RADIUS_LOAD+1)^2 square. Real
## shape/size tuning against the actual Mojave worldspace is
## phases/2/08-world-cell-streaming.md's own explicitly-deferred follow-on,
## not this task's job -- this is a starting value to get the mechanism
## correct, not a measured one.
const RADIUS_LOAD := 1

## Hysteresis: a resident tile isn't unloaded until it's past this larger
## radius, not the same threshold load uses -- otherwise a camera sitting
## almost exactly on the load boundary would thrash load/unload every
## check. Must stay > RADIUS_LOAD.
const RADIUS_UNLOAD := 2

## How often (seconds) to re-check the resident set against the camera's
## current position -- continuous, not boundary-cross-triggered, but a
## real-time interval rather than literally every single frame (streaming
## doesn't need sub-frame precision on when a check happens, only that gaps
## never open up before a tile has time to load in with margin).
const CHECK_INTERVAL_SEC := 0.5

## How many REFRs to place per frame before yielding, same meaning as
## CellLoader's own -- see CellStreamBuilder.
@export var objects_per_frame: int = 20

var esm: EsmReader
var resolver: GamebryoMeshResolver
var registry: GamebryoObjectRegistry
var _builder: CellStreamBuilder

var _active_wrld_form_id: int = -1 # -1 == inactive
var _generation := 0 # bumped on every activate()/deactivate() -- invalidates stale in-flight tile streams
var _resident: Dictionary = {} # Vector2i grid coord -> built tile root Node3D
var _pending: Dictionary = {} # Vector2i grid coord -> true, currently streaming in
var _persistent_root: Node3D = null
var _in_flight_count := 0
var _check_timer := 0.0

func _ready() -> void:
	esm = EsmReader.new()
	if not esm.open(DATA_DIR + "FalloutNV.esm"):
		push_error("WorldStreamer: could not open FalloutNV.esm")
	resolver = GamebryoMeshResolver.new()
	registry = GamebryoObjectRegistry.new(resolver, esm)
	_builder = CellStreamBuilder.new(esm, resolver, registry, objects_per_frame)

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
	for coord in _resident:
		_resident[coord].free()
	_resident.clear()
	_pending.clear()
	if _persistent_root != null:
		_persistent_root.free()
		_persistent_root = null
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

	for dx in range(-RADIUS_LOAD, RADIUS_LOAD + 1):
		for dy in range(-RADIUS_LOAD, RADIUS_LOAD + 1):
			var coord := Vector2i(center.x + dx, center.y + dy)
			if not _resident.has(coord) and not _pending.has(coord):
				_start_tile_load(coord)

	for coord in _resident.keys().duplicate():
		if absi(coord.x - center.x) > RADIUS_UNLOAD or absi(coord.y - center.y) > RADIUS_UNLOAD:
			_resident[coord].free()
			_resident.erase(coord)

func _start_tile_load(coord: Vector2i) -> void:
	var cell: Dictionary = esm.find_exterior_cell(_active_wrld_form_id, coord.x, coord.y)
	if cell.is_empty():
		return # no cell at this grid coordinate -- a real case at a worldspace's edge, not an error
	_pending[coord] = true
	_in_flight_count += 1
	_stream_tile(int(cell["form_id"]), coord, _generation)

func _stream_tile(cell_form_id: int, coord: Vector2i, my_generation: int) -> void:
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

	var terrain := _builder.build_terrain(cell_form_id)
	if terrain != null:
		CellStreamBuilder.set_collision_disabled(terrain, true)
		terrain_root.add_child(terrain)

	# Deliberately NOT get_persistent_refs_for_cell() here -- persistent
	# refs are streamed exactly once into PersistentRoot by
	# _stream_persistent_root(), never per-tile (see this class's own doc
	# comment on why).
	var refs: Array = esm.get_cell_references(cell_form_id)

	var add_child_fn := func(parent: Node, child: Node) -> void:
		parent.add_child(child)
		CellStreamBuilder.set_collision_disabled(child, true)
	var is_cancelled_fn := func() -> bool: return my_generation != _generation
	var completed: bool = await _builder.stream_refs(refr_root, refs, add_child_fn, is_cancelled_fn)

	_pending.erase(coord)
	_in_flight_count -= 1
	if not completed or my_generation != _generation:
		tile_root.free() # superseded/deactivated -- never was resident, safe to free
		_maybe_emit_settled()
		return

	CellStreamBuilder.set_collision_disabled(tile_root, false)
	tile_root.visible = true
	_resident[coord] = tile_root
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

	_in_flight_count += 1
	var add_child_fn := func(parent: Node, child: Node) -> void:
		parent.add_child(child)
		CellStreamBuilder.set_collision_disabled(child, true)
	var is_cancelled_fn := func() -> bool: return my_generation != _generation
	var completed: bool = await _builder.stream_refs(refr_root, refs, add_child_fn, is_cancelled_fn)

	_in_flight_count -= 1
	if not completed or my_generation != _generation:
		root.free() # deactivated mid-stream -- never was live, safe to free
		_maybe_emit_settled()
		return

	CellStreamBuilder.set_collision_disabled(root, false)
	root.visible = true
	_persistent_root = root
	_maybe_emit_settled()

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
func get_current_cell_form_id() -> int:
	if _active_wrld_form_id == -1:
		return 0
	var coord: Variant = _current_grid_coord()
	if coord == null:
		return 0
	return _tile_cell_form_id(coord)
