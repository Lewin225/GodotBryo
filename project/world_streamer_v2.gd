class_name WorldStreamerV2
extends Node3D

## Typed exterior-object streaming over:
## EsmServer -> EsmReferencePhysicaliser -> EsmNode -> NifServer.
##
## This first version deliberately contains no resolver pool, mesh construction,
## DirectGeometryBatch or render-server work. A resident tile owns typed
## semantic nodes; VWD nodes use their paired NIF LOD in the outer ring.

const PhysicaliserScript := preload("res://GodotBryo/Pipeline/esm_reference_physicaliser.gd")

signal streaming_settled

const RADIUS_UNLOAD_FLOOR := 5.0
const CHECK_INTERVAL_SEC := 0.1
const CELL_SIZE_METERS := CellStreamBuilder.CELL_SIZE_UNITS * CellStreamBuilder.GAMEBRYO_UNITS_TO_METERS
const SPAWN_REFR := 1 << 0
const SPAWN_ACHR := 1 << 1
const SPAWN_CREA := 1 << 2

## Full-detail semantic radius. It starts at twice V2's original two-cell
## radius and remains Inspector-tunable while exterior residency is settled.
@export_range(1.0, 16.0, 0.5, "or_greater") var load_radius := 4.0
## Wider VWD-only companion-LOD radius. This bounds semantic nodes too: the
## outer ring never instantiates non-VWD references or their full NIFs.
@export_range(1.0, 32.0, 0.5, "or_greater") var lod_load_radius := 8.0
@export var objects_per_frame := 40
@export var tiles_per_frame := 1
@export var freeze_trace_enabled := false

## Placement categories WorldStreamerV2 is allowed to physicalise. `ACHR`
## currently takes the retained legacy EsmHumanoidActor assembly path; leave it off
## when profiling only the new server pipeline. `CREA` is kept separately for
## the same reason as creature assembly arrives.
@export_flags("REFR", "ACHR", "CREA") var spawn_reference_types := SPAWN_REFR | SPAWN_ACHR | SPAWN_CREA

var esm_server: Node = null
var _physicaliser := PhysicaliserScript.new()
var _active_wrld_form_id := -1
var _paused := false
## Game transitions pause and hide by default; the profiler can instead pause
## scheduling while retaining visible, collidable exterior state.
var _pause_hides := true
var _generation := 0
var _check_timer := 0.0
var _current_cell_form_id_cache := 0
var _initial_center: Variant = null
var _waiting_for_esm := false
var _settled_generation := -1

## Kept observable while the streaming debug UI is rebuilt. They contain only
## semantic Node3D roots, never legacy RIDs or resolved geometry entries.
var _resident: Dictionary = {}
var _tile_references: Dictionary = {}
var _pending: Dictionary = {}
var _queued: Dictionary = {}
var _load_queue: Array[Vector2i] = []
var _no_cell_cache: Dictionary = {}
var _persistent_root: Node3D = null
var _persistent_imposter_root: Node3D = null
var _persistent_tiles: Dictionary = {}
var _persistent_references_by_tile: Dictionary = {}
var _persistent_pending: Dictionary = {}
var _persistent_queued: Dictionary = {}
var _persistent_load_queue: Array[Vector2i] = []
## Worldspace-wide XSRF/XSRD stand-ins.  These must eventually exist beyond
## ordinary tile residency, but never get to occupy NifServer ahead of cells
## around the camera.
var _persistent_imposter_queue: Array[EsmReference] = []

var _tile_population_jobs: Array[Dictionary] = []
var _persistent_population_jobs: Array[Dictionary] = []


func _ready() -> void:
	_resolve_esm_server()


func activate(worldspace_form_id: int) -> void:
	if _active_wrld_form_id == worldspace_form_id:
		set_paused(false)
		return
	deactivate()
	_active_wrld_form_id = worldspace_form_id
	_generation += 1
	_settled_generation = -1
	_initial_center = null
	if _esm_is_ready():
		_begin_streaming()


func deactivate() -> void:
	if _active_wrld_form_id == -1:
		return
	_active_wrld_form_id = -1
	_generation += 1
	_paused = false
	_pause_hides = true
	visible = true
	_current_cell_form_id_cache = 0
	_initial_center = null
	_waiting_for_esm = false
	_no_cell_cache.clear()
	_tile_references.clear()
	_pending.clear()
	_queued.clear()
	_load_queue.clear()
	_tile_population_jobs.clear()
	_persistent_tiles.clear()
	_persistent_references_by_tile.clear()
	_persistent_pending.clear()
	_persistent_queued.clear()
	_persistent_load_queue.clear()
	_persistent_imposter_queue.clear()
	_persistent_population_jobs.clear()
	for root: Node3D in _resident.values():
		root.free()
	_resident.clear()
	if _persistent_root != null:
		_persistent_root.free()
		_persistent_root = null
	_persistent_imposter_root = null


func is_active() -> bool:
	return _active_wrld_form_id != -1


func is_paused() -> bool:
	return _paused



func is_pause_hiding() -> bool:
	return _paused and _pause_hides


## Pausing retains exterior state for an interior return, while suppressing
## visibility and collision. EsmNode reapplies this state to late NIF trees.
func set_paused(paused: bool, hide_when_paused := true) -> void:
	if not is_active():
		return
	var next_pause_hides := hide_when_paused if paused else false
	if paused == _paused and next_pause_hides == _pause_hides:
		return
	_paused = paused
	_pause_hides = next_pause_hides
	visible = not (_paused and _pause_hides)
	for root: Node3D in _resident.values():
		apply_streaming_state_to_subtree(root)
	if _persistent_root != null:
		apply_streaming_state_to_subtree(_persistent_root)
	if not paused:
		# Game connects a fresh streaming_settled listener before activate() on
		# every exterior return. A retained same-worldspace root must therefore
		# settle again, despite no new tile construction being necessary.
		_settled_generation = -1
		_check_streaming()
		call_deferred("_maybe_emit_initial_settled")

## Called by EsmNode when NifServer delivers a tree after a stream-state
## change.
func apply_streaming_state_to_subtree(node: Node) -> void:
	CellStreamBuilder.set_collision_disabled(node, _paused and _pause_hides)

func _process(delta: float) -> void:
	if not is_active() or _paused or not _esm_is_ready():
		return
	_process_tile_starts()
	_process_population()
	_check_timer -= delta
	if _check_timer <= 0.0:
		_check_timer = CHECK_INTERVAL_SEC
		_check_streaming()
	_maybe_emit_initial_settled()


func _resolve_esm_server() -> bool:
	if esm_server != null and is_instance_valid(esm_server):
		return true
	var root := get_tree().root if get_tree() != null else null
	esm_server = root.get_node_or_null("EsmServer") if root != null else null
	return esm_server != null


func _esm_is_ready() -> bool:
	if not _resolve_esm_server():
		return false
	if esm_server.has_method("is_ready") and esm_server.is_ready():
		return true
	if not _waiting_for_esm and esm_server.has_signal("esm_ready"):
		_waiting_for_esm = true
		esm_server.esm_ready.connect(_on_esm_ready, CONNECT_ONE_SHOT)
	return false


func _on_esm_ready() -> void:
	_waiting_for_esm = false
	if is_active() and not _paused:
		_begin_streaming()


func _begin_streaming() -> void:
	if not is_active() or _paused or not _esm_is_ready():
		return
	if _persistent_root == null:
		_begin_persistent_root()
	_check_streaming()


func _active_camera() -> Camera3D:
	return get_viewport().get_camera_3d() if get_viewport() != null else null


func _current_grid_coord() -> Variant:
	var camera := _active_camera()
	if camera == null:
		return null
	return Vector2i(
		floori(camera.global_position.x / CELL_SIZE_METERS),
		floori(-camera.global_position.z / CELL_SIZE_METERS)
	)


static func _within_radius(dx: int, dy: int, radius: float) -> bool:
	return dx * dx + dy * dy <= radius * radius


func _check_streaming() -> void:
	if not is_active() or _paused or not _esm_is_ready():
		return
	var center: Variant = _current_grid_coord()
	if center == null:
		return
	_current_cell_form_id_cache = esm_server.get_exterior_cell_form_id(_active_wrld_form_id, center)
	if _initial_center == null:
		_initial_center = center
	var candidates: Array[Vector2i] = []
	var lod_radius := _lod_radius()
	var bound := ceili(lod_radius)
	for dx in range(-bound, bound + 1):
		for dy in range(-bound, bound + 1):
			if not _within_radius(dx, dy, lod_radius):
				continue
			var coord := Vector2i(center.x + dx, center.y + dy)
			if _no_cell_cache.has(coord) or _resident.has(coord) or _pending.has(coord) or _queued.has(coord):
				continue
			candidates.append(coord)
	candidates.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.distance_squared_to(center) < b.distance_squared_to(center)
	)
	for coord in candidates:
		_queued[coord] = true
		_load_queue.append(coord)
	for coord: Vector2i in _resident.keys().duplicate():
		var distance_x: int = coord.x - center.x
		var distance_y: int = coord.y - center.y
		if not _within_radius(distance_x, distance_y, _unload_radius()):
			_remove_tile(coord)
		else:
			_set_tile_visual_detail(_resident[coord], _detail_for_offset(distance_x, distance_y))
	_check_persistent_tiles(center)
	_prioritize_persistent_imposters(center)
	_process_tile_starts()


## Always leave at least one cell of hysteresis, even if an Inspector value is
## raised past the original unload radius.
func _unload_radius() -> float:
	return maxf(RADIUS_UNLOAD_FLOOR, _lod_radius() + 1.0)


func _lod_radius() -> float:
	return maxf(load_radius, lod_load_radius)


func _detail_for_offset(dx: int, dy: int) -> EsmNode.VisualDetail:
	return EsmNode.VisualDetail.FULL if _within_radius(dx, dy, load_radius) else EsmNode.VisualDetail.LOD


func _process_tile_starts() -> void:
	var budget := maxi(1, tiles_per_frame)
	var center_value: Variant = _current_grid_coord()
	if center_value == null:
		return
	var center: Vector2i = center_value
	_sort_tile_start_queues(center)
	while budget > 0 and (not _load_queue.is_empty() or not _persistent_load_queue.is_empty()):
		var regular_distance: float = INF if _load_queue.is_empty() else _load_queue[0].distance_squared_to(center)
		var persistent_distance: float = INF if _persistent_load_queue.is_empty() else _persistent_load_queue[0].distance_squared_to(center)
		var start_persistent := persistent_distance < regular_distance
		if not start_persistent:
			var coord: Vector2i = _load_queue.pop_front()
			_queued.erase(coord)
			if not is_active() or _paused or _resident.has(coord) or _pending.has(coord) or _no_cell_cache.has(coord):
				continue
			if not _within_radius(coord.x - center.x, coord.y - center.y, _lod_radius()):
				continue
			_start_tile(coord, _detail_for_offset(coord.x - center.x, coord.y - center.y))
		else:
			_start_persistent_tile(_persistent_load_queue.pop_front())
		budget -= 1


func _sort_tile_start_queues(center: Vector2i) -> void:
	_load_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.distance_squared_to(center) < b.distance_squared_to(center)
	)
	_persistent_load_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.distance_squared_to(center) < b.distance_squared_to(center)
	)


func _start_tile(coord: Vector2i, detail: EsmNode.VisualDetail) -> void:
	var cell_form_id: int = esm_server.get_exterior_cell_form_id(_active_wrld_form_id, coord)
	if cell_form_id == 0:
		_no_cell_cache[coord] = true
		return
	var root := Node3D.new()
	root.name = "Tile_%d_%d" % [coord.x, coord.y]
	root.set_meta("cell_form_id", cell_form_id)
	root.set_meta("grid_coord", coord)
	root.set_meta("visual_detail", detail)
	add_child(root)
	_resident[coord] = root
	_pending[coord] = true
	var references: Array[EsmReference] = esm_server.get_references_in_cell(cell_form_id)
	_tile_references[coord] = references
	root.set_meta("references", references)
	_queue_population(root, references, false)


func _begin_persistent_root() -> void:
	var root := Node3D.new()
	root.name = "PersistentRoot"
	add_child(root)
	_persistent_root = root
	var references: Array[EsmReference] = esm_server.get_persistent_references_for_worldspace(_active_wrld_form_id)
	var imposter_root := Node3D.new()
	imposter_root.name = "PersistentImposters"
	root.add_child(imposter_root)
	_persistent_imposter_root = imposter_root
	for reference in references:
		if reference == null:
			continue
		if reference.has_xsrf_or_xsrd:
			# These stand-ins have no paired NIF and must remain available beyond
			# the ordinary resident radius. Queue them for idle time instead of
			# submitting the whole worldspace before nearby cell models.
			if _should_spawn(reference):
				_persistent_imposter_queue.append(reference)
			continue
		var coord := _authored_grid_coord(reference.position)
		if not _persistent_references_by_tile.has(coord):
			_persistent_references_by_tile[coord] = []
		_persistent_references_by_tile[coord].append(reference)


## Persistent REFRs are worldspace-owned, but their authored positions still
## put them in a grid tile. Bucket them once, then give them the same near/LOD
## policy as ordinary CELL references without per-node camera processing.
func _authored_grid_coord(position: Vector3) -> Vector2i:
	return Vector2i(
		floori(position.x / CELL_SIZE_METERS),
		floori(position.y / CELL_SIZE_METERS)
	)


func _check_persistent_tiles(center: Vector2i) -> void:
	var candidates: Array[Vector2i] = []
	for coord: Vector2i in _persistent_references_by_tile.keys():
		var dx: int = coord.x - center.x
		var dy: int = coord.y - center.y
		if _within_radius(dx, dy, _lod_radius()):
			if not _persistent_tiles.has(coord) and not _persistent_pending.has(coord) and not _persistent_queued.has(coord):
				candidates.append(coord)
	for coord: Vector2i in _persistent_tiles.keys().duplicate():
		var dx: int = coord.x - center.x
		var dy: int = coord.y - center.y
		if not _within_radius(dx, dy, _unload_radius()):
			_remove_persistent_tile(coord)
		else:
			_set_tile_visual_detail(_persistent_tiles[coord], _detail_for_offset(dx, dy))
	candidates.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.distance_squared_to(center) < b.distance_squared_to(center)
	)
	for coord in candidates:
		_persistent_queued[coord] = true
		_persistent_load_queue.append(coord)


func _prioritize_persistent_imposters(center: Vector2i) -> void:
	_persistent_imposter_queue.sort_custom(func(a: EsmReference, b: EsmReference) -> bool:
		return _authored_grid_coord(a.position).distance_squared_to(center) < _authored_grid_coord(b.position).distance_squared_to(center)
	)


func _start_persistent_tile(coord: Vector2i) -> void:
	_persistent_queued.erase(coord)
	if not is_active() or _paused or _persistent_root == null or _persistent_tiles.has(coord) or _persistent_pending.has(coord):
		return
	var center_value: Variant = _current_grid_coord()
	if center_value == null:
		return
	var center: Vector2i = center_value
	if not _within_radius(coord.x - center.x, coord.y - center.y, _lod_radius()):
		return
	var root := Node3D.new()
	root.name = "PersistentTile_%d_%d" % [coord.x, coord.y]
	root.set_meta("grid_coord", coord)
	root.set_meta("visual_detail", _detail_for_offset(coord.x - center.x, coord.y - center.y))
	_persistent_root.add_child(root)
	_persistent_tiles[coord] = root
	_persistent_pending[coord] = true
	var references: Array = _persistent_references_by_tile.get(coord, [])
	root.set_meta("references", references)
	_queue_population(root, references, true)


func _queue_population(root: Node3D, references: Array, persistent: bool) -> void:
	var coord: Vector2i = root.get_meta("grid_coord", Vector2i.ZERO)
	var job := {
		"coord": coord,
		"root": root,
		"references": references,
		"next_index": 0,
		"generation": _generation,
	}
	if persistent:
		_persistent_population_jobs.append(job)
	else:
		_tile_population_jobs.append(job)


func _process_population() -> void:
	var budget := maxi(1, objects_per_frame)
	while budget > 0:
		var is_tile_job := not _tile_population_jobs.is_empty()
		var is_persistent_job := not _persistent_population_jobs.is_empty()
		if not is_tile_job and not is_persistent_job:
			if _load_queue.is_empty() and _persistent_load_queue.is_empty() and not _persistent_imposter_queue.is_empty():
				var center_value: Variant = _current_grid_coord()
				if center_value != null:
					_prioritize_persistent_imposters(center_value)
				var imposter: EsmReference = _persistent_imposter_queue.pop_front()
				if _persistent_imposter_root != null and is_instance_valid(_persistent_imposter_root):
					_physicaliser.physicalise(imposter, _persistent_imposter_root, EsmNode.VisualDetail.FULL)
				budget -= 1
				continue
			return
		var center_value: Variant = _current_grid_coord()
		if center_value == null:
			return
		var center: Vector2i = center_value
		var tile_index := _closest_population_job_index(_tile_population_jobs, center)
		var persistent_index := _closest_population_job_index(_persistent_population_jobs, center)
		var tile_distance: float = INF if tile_index == -1 else Vector2i(_tile_population_jobs[tile_index].get("coord", Vector2i.ZERO)).distance_squared_to(center)
		var persistent_distance: float = INF if persistent_index == -1 else Vector2i(_persistent_population_jobs[persistent_index].get("coord", Vector2i.ZERO)).distance_squared_to(center)
		var use_persistent := persistent_distance < tile_distance
		var job_index := persistent_index if use_persistent else tile_index
		var job: Dictionary = _persistent_population_jobs[job_index] if use_persistent else _tile_population_jobs[job_index]
		if int(job.get("generation", -1)) != _generation or not is_instance_valid(job.get("root")):
			if not use_persistent:
				_pending.erase(job.get("coord", Vector2i.ZERO))
				_tile_population_jobs.remove_at(job_index)
			else:
				_persistent_pending.erase(job.get("coord", Vector2i.ZERO))
				_persistent_population_jobs.remove_at(job_index)
			continue
		var references: Array = job.get("references", [])
		var next_index := int(job.get("next_index", 0))
		if next_index >= references.size():
			if not use_persistent:
				_pending.erase(job.get("coord", Vector2i.ZERO))
				_tile_population_jobs.remove_at(job_index)
			else:
				_persistent_pending.erase(job.get("coord", Vector2i.ZERO))
				_persistent_population_jobs.remove_at(job_index)
			continue
		var reference: EsmReference = references[next_index]
		job["next_index"] = next_index + 1
		if not use_persistent:
			_tile_population_jobs[job_index] = job
		else:
			_persistent_population_jobs[job_index] = job
		var detail: EsmNode.VisualDetail = int(job["root"].get_meta("visual_detail", EsmNode.VisualDetail.FULL))
		if reference != null and _should_physicalise(reference, detail) and not _has_physicalised_reference(job["root"], reference):
			_physicaliser.physicalise(reference, job["root"], detail)
		budget -= 1


func _closest_population_job_index(jobs: Array[Dictionary], center: Vector2i) -> int:
	var closest_index := -1
	var closest_distance := INF
	for index in jobs.size():
		var coord: Vector2i = jobs[index].get("coord", Vector2i.ZERO)
		var distance := coord.distance_squared_to(center)
		if distance < closest_distance:
			closest_distance = distance
			closest_index = index
	return closest_index


func _should_spawn(reference: EsmReference) -> bool:
	if reference is ActorReference:
		return (spawn_reference_types & SPAWN_ACHR) != 0
	if reference is CreatureReference:
		return (spawn_reference_types & SPAWN_CREA) != 0
	return (spawn_reference_types & SPAWN_REFR) != 0


func _should_physicalise(reference: EsmReference, detail: EsmNode.VisualDetail) -> bool:
	if not _should_spawn(reference):
		return false
	if detail == EsmNode.VisualDetail.FULL:
		return true
	# SCOL builds authored component placements, not the collection's own NIF;
	# it therefore has no paired-tree path yet. Actor classes own separate
	# assembly lifecycles. Do not accidentally make either load full detail in
	# the VWD-only ring.
	return reference.visible_when_distant \
		and not reference is StaticCollectionReference \
		and not reference is ActorReference \
		and not reference is CreatureReference


func _remove_tile(coord: Vector2i) -> void:
	_pending.erase(coord)
	if _resident.has(coord):
		var root: Node3D = _resident[coord]
		root.free()
		_resident.erase(coord)
	_tile_references.erase(coord)


func _remove_persistent_tile(coord: Vector2i) -> void:
	_persistent_pending.erase(coord)
	if _persistent_tiles.has(coord):
		var root: Node3D = _persistent_tiles[coord]
		root.free()
		_persistent_tiles.erase(coord)


## Tile state is the only camera-driven input. A property assignment is
## idempotent, so each semantic node receives at most one request per actual
## band transition, never a distance check every frame.
func _set_tile_visual_detail(root: Node, detail: EsmNode.VisualDetail) -> void:
	var previous := int(root.get_meta("visual_detail", -1))
	if previous == detail:
		return
	root.set_meta("visual_detail", detail)
	if detail == EsmNode.VisualDetail.LOD:
		_prune_tile_to_lod(root)
	_set_subtree_visual_detail(root, detail)
	if detail == EsmNode.VisualDetail.FULL:
		var references: Array = root.get_meta("references", [])
		var coord: Vector2i = root.get_meta("grid_coord", Vector2i.ZERO)
		var persistent := root.get_parent() == _persistent_root
		if persistent:
			_persistent_pending[coord] = true
		else:
			_pending[coord] = true
		_queue_population(root as Node3D, references, persistent)


func _prune_tile_to_lod(root: Node) -> void:
	for child in root.get_children().duplicate():
		if child is EsmNode and not _should_physicalise(child.reference, EsmNode.VisualDetail.LOD):
			child.free()


func _has_physicalised_reference(root: Node, reference: EsmReference) -> bool:
	for child in root.get_children():
		if child is EsmNode and child.reference != null and child.reference.instance_id == reference.instance_id:
			return true
	return false


func _set_subtree_visual_detail(node: Node, detail: EsmNode.VisualDetail) -> void:
	for child in node.get_children():
		if child is EsmNode:
			child.visual_detail = detail
		_set_subtree_visual_detail(child, detail)


func _maybe_emit_initial_settled() -> void:
	if _settled_generation == _generation or not is_active() or _paused or _initial_center == null:
		return
	if _persistent_root == null:
		return
	if not _resident.has(_initial_center) and not _no_cell_cache.has(_initial_center):
		return
	_settled_generation = _generation
	streaming_settled.emit()


func get_current_cell_form_id() -> int:
	return _current_cell_form_id_cache if is_active() else 0


func get_current_refs() -> Array[EsmReference]:
	var result: Array[EsmReference] = []
	for root: Node3D in _resident.values():
		_append_root_references(root, result)
	if _persistent_root != null:
		_append_root_references(_persistent_root, result)
	return result


func _append_root_references(root: Node, output: Array[EsmReference]) -> void:
	for child in root.get_children():
		if child is EsmNode and child.reference != null:
			output.append(child.reference)
		else:
			_append_root_references(child, output)
