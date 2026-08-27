class_name TerrainStreamer
extends Node3D

## Finite-domain terrain owner. Complete native-composed regions are scheduled
## near-first while a guaranteed background share drains the whole worldspace.

signal state_changed

enum ReadyStatus { READY, CANCELLED, SUPERSEDED }

const GameDataConfigScript := preload("res://game_data_config.gd")
const RADIUS_LOAD := 20.0
const CHECK_INTERVAL_SEC := 0.1
const FAR_SLOT_INTERVAL := 4
const MAX_WORKERS := 8
const DEFAULT_REGIONS_PER_FRAME := 1
const CELL_SIZE_METERS := CellStreamBuilder.CELL_SIZE_UNITS * CellStreamBuilder.GAMEBRYO_UNITS_TO_METERS

## Cache families are derived from the configured master, never from authored
## EditorIDs/FormID ranges embedded in source. This keeps worldspace discovery
## data-driven and allows the same streamer to run against another game's ESM.
const CACHE_FAMILY_PREFIX := "esm:"

@export var tiles_per_frame := 3
@export var load_radius := RADIUS_LOAD
@export_range(1, 8, 1) var regions_per_frame := DEFAULT_REGIONS_PER_FRAME
@export var terrain3d_debug_dump_grid := Vector2i(999999, 999999)

var esm: EsmReader
var resolver: GamebryoMeshResolver
var terrain: Terrain3D
var texture_pool: Terrain3DTexturePool
var bridge: Terrain3DBridge
var grass: TerrainGrassParticles
var diagnostic_terrain_ms: Array[float] = []
var diagnostic_publication_ms: Array[float] = []
var diagnostic_staging_ms: Array[float] = []
var diagnostic_collision_updates := 0

var _configured := false
var _cache_family_by_worldspace: Dictionary = {}
var _cache_family := ""
## worldspace FormID -> complete retained terrain runtime entry. Worker tasks
## are deliberately not retained: inactive entries preserve committed maps and
## queue domain, while any in-flight detached task is generation-rejected.
var _worldspace_entries: Dictionary = {}
var _active_wrld_form_id := -1
var _paused := false
var _generation := 0
var _resident: Dictionary = {}
var _desired_cells: Dictionary = {}
var _usable_cells: Dictionary = {}
var _touched_regions: Dictionary = {}
var _committed_regions: Dictionary = {}
var _region_states: Dictionary = {}
var _region_cells: Dictionary = {}
var _priority_hints: Dictionary = {}
var _prepared_regions: Array[Dictionary] = []
var _logical_slots: Dictionary = {}
var _catalogue: Dictionary = {}
var _catalogue_failed := false
var _catalogue_error := ""
var _workers: Array[Dictionary] = []
var _idle_stagers: Array[TerrainRegionStager] = []
var _worker_count := 1
var _dispatch_count := 0
var _indexing := false
## Reaping records retain the originating entry's stager array. A completed
## detached task must return its ESM-backed stager to that entry, not whichever
## worldspace happens to be active when the task finishes.
var _abandoned_tasks: Array[Dictionary] = []
var _check_timer := 0.0
var _last_center: Variant = null
var _cancelled_generations: Dictionary = {}
var _ready_collision_centers: Dictionary = {}
var _terrain_unavailable := false

func configure(esm_reader: EsmReader, mesh_resolver: GamebryoMeshResolver) -> void:
	esm = esm_reader
	resolver = mesh_resolver
	_configured = esm != null and resolver != null
	if _configured:
		# GameDataConfig is the authoritative selected master for this runtime.
		# The value is a source identifier, not a list of content records.
		_cache_family = CACHE_FAMILY_PREFIX + GameDataConfigScript.ESM_FILE
		_cache_family_by_worldspace.clear()

func _ready() -> void:
	if _configured:
		return
	var data_dir := GameDataSettings.get_data_dir()
	var fallback_esm := EsmReader.new()
	if not fallback_esm.open(data_dir + GameDataConfigScript.ESM_FILE):
		push_error("TerrainStreamer fallback could not open FalloutNV.esm")
		return
	configure(fallback_esm, GamebryoMeshResolver.new(data_dir))

func activate(worldspace_form_id: int) -> void:
	if _active_wrld_form_id == worldspace_form_id:
		set_paused(false)
		return
	# Worldspaces are discovered by the worker-side ESM catalogue. Do not reject
	# IDs here: DLC/mod worldspaces must still complete the transition even when
	# this runtime cannot stage terrain for them.
	_cache_family_by_worldspace[worldspace_form_id] = _cache_family
	if is_active():
		_suspend_active_entry()
	if _worldspace_entries.has(worldspace_form_id):
		_restore_entry(_worldspace_entries[worldspace_form_id])
		_resume_active_entry()
	else:
		_create_entry(worldspace_form_id)
	state_changed.emit()

## Explicit final teardown. Normal Mojave-family switches use activate(), which
## suspends and retains the outgoing entry; only this call releases entries.
func deactivate() -> void:
	if is_active():
		_suspend_active_entry()
	for entry: Dictionary in _worldspace_entries.values():
		_free_entry(entry)
	_worldspace_entries.clear()
	_clear_active_references()
	state_changed.emit()

func _create_entry(worldspace_form_id: int) -> void:
	_clear_active_references()
	_generation += 1
	_active_wrld_form_id = worldspace_form_id
	_paused = false
	diagnostic_terrain_ms.clear()
	diagnostic_publication_ms.clear()
	diagnostic_staging_ms.clear()
	diagnostic_collision_updates = 0
	_ready_collision_centers.clear()
	_terrain_unavailable = false
	terrain = Terrain3DBridge.create_terrain(self)
	texture_pool = Terrain3DTexturePool.new(terrain)
	bridge = Terrain3DBridge.new(esm, resolver, texture_pool)
	bridge.debug_dump_grid = terrain3d_debug_dump_grid
	grass = TerrainGrassParticles.new(terrain, bridge, esm, resolver)
	add_child(grass)
	_bind_camera()
	terrain.set_physics_process(true)
	terrain.set_collision_mode(Terrain3DCollision.DYNAMIC_GAME)
	_start_catalogue_job()
	_worldspace_entries[worldspace_form_id] = _capture_active_entry()

func _suspend_active_entry() -> void:
	if not is_active():
		return
	# Invalidate before changing any visible/physics state. Detached workers are
	# reaped globally, but no result can publish into this now-inactive entry.
	_cancel_current_generation()
	for location: Vector2i in _region_states:
		if _region_states[location] in ["queued", "preparing", "prepared"]:
			_region_states[location] = "cancelled"
	_prepared_regions.clear()
	_abandon_workers()
	_ready_collision_centers.clear()
	if terrain != null:
		terrain.visible = false
		terrain.set_physics_process(false)
		terrain.set_collision_mode(Terrain3DCollision.DISABLED)
	if grass != null:
		grass.set_enabled(false)
	var entry := _capture_active_entry()
	entry["active"] = false
	_worldspace_entries[_active_wrld_form_id] = entry
	_clear_active_references()

func _resume_active_entry() -> void:
	_paused = false
	_generation += 1
	_ready_collision_centers.clear()
	visible = true
	if terrain != null:
		terrain.visible = true
		_bind_camera()
		terrain.set_physics_process(true)
		terrain.set_collision_mode(Terrain3DCollision.DYNAMIC_GAME)
	if grass != null:
		# Enable the controller before coverage, but leave emitters stopped until
		# that coverage pass identifies the current camera's committed textures.
		grass.set_enabled(true, false)
		_update_grass_coverage()
	_requeue_uncommitted_regions()
	_ensure_worker_pool()
	_check_streaming()
	var entry := _capture_active_entry()
	entry["active"] = true
	_worldspace_entries[_active_wrld_form_id] = entry

func _capture_active_entry() -> Dictionary:
	return {
		"worldspace_form_id": _active_wrld_form_id,
		"cache_family": _cache_family_by_worldspace.get(_active_wrld_form_id, ""),
		"active": true, "terrain": terrain, "texture_pool": texture_pool, "bridge": bridge, "grass": grass,
		"generation": _generation, "resident": _resident, "desired_cells": _desired_cells,
		"usable_cells": _usable_cells, "touched_regions": _touched_regions,
		"committed_regions": _committed_regions, "region_states": _region_states,
		"region_cells": _region_cells, "priority_hints": _priority_hints,
		"prepared_regions": _prepared_regions, "logical_slots": _logical_slots, "catalogue": _catalogue,
		"catalogue_failed": _catalogue_failed, "catalogue_error": _catalogue_error,
		"idle_stagers": _idle_stagers, "worker_count": _worker_count,
		"dispatch_count": _dispatch_count, "indexing": _indexing, "last_center": _last_center,
		"cancelled_generations": _cancelled_generations, "ready_collision_centers": _ready_collision_centers,
		"terrain_unavailable": _terrain_unavailable,
		"terrain_ms": diagnostic_terrain_ms, "staging_ms": diagnostic_staging_ms,
		"publication_ms": diagnostic_publication_ms, "collision_updates": diagnostic_collision_updates,
	}

func _restore_entry(entry: Dictionary) -> void:
	_active_wrld_form_id = int(entry.worldspace_form_id)
	terrain = entry.terrain as Terrain3D
	texture_pool = entry.texture_pool as Terrain3DTexturePool
	bridge = entry.bridge as Terrain3DBridge
	grass = entry.grass as TerrainGrassParticles
	_generation = int(entry.generation)
	_resident = entry.resident
	_desired_cells = entry.desired_cells
	_usable_cells = entry.usable_cells
	_touched_regions = entry.touched_regions
	_committed_regions = entry.committed_regions
	_region_states = entry.region_states
	_region_cells = entry.region_cells
	_priority_hints = entry.priority_hints
	_prepared_regions = entry.prepared_regions
	_logical_slots = entry.logical_slots
	_catalogue = entry.catalogue
	_catalogue_failed = bool(entry.get("catalogue_failed", false))
	_catalogue_error = String(entry.get("catalogue_error", ""))
	_idle_stagers = entry.idle_stagers
	_worker_count = int(entry.worker_count)
	_dispatch_count = int(entry.dispatch_count)
	_indexing = bool(entry.indexing)
	_last_center = entry.last_center
	_cancelled_generations = entry.cancelled_generations
	_ready_collision_centers = entry.ready_collision_centers
	_terrain_unavailable = bool(entry.get("terrain_unavailable", false))
	diagnostic_terrain_ms = entry.terrain_ms
	diagnostic_staging_ms = entry.staging_ms
	diagnostic_publication_ms = entry.publication_ms
	diagnostic_collision_updates = int(entry.collision_updates)

func _clear_active_references() -> void:
	_active_wrld_form_id = -1
	_paused = false
	terrain = null
	texture_pool = null
	bridge = null
	grass = null
	_resident = {}; _desired_cells = {}; _usable_cells = {}; _touched_regions = {}
	_committed_regions = {}; _region_states = {}; _region_cells = {}; _priority_hints = {}
	_prepared_regions = []; _logical_slots = {}; _catalogue = {}; _catalogue_failed = false; _catalogue_error = ""; _idle_stagers = []
	_worker_count = 1; _dispatch_count = 0; _indexing = false; _last_center = null
	_cancelled_generations = {}; _ready_collision_centers = {}
	_terrain_unavailable = false
	diagnostic_terrain_ms = []
	diagnostic_staging_ms = []
	diagnostic_publication_ms = []
	diagnostic_collision_updates = 0

func _free_entry(entry: Dictionary) -> void:
	var entry_grass := entry.get("grass") as TerrainGrassParticles
	var entry_terrain := entry.get("terrain") as Terrain3D
	if entry_grass != null and is_instance_valid(entry_grass):
		entry_grass.free()
	if entry_terrain != null and is_instance_valid(entry_terrain):
		entry_terrain.free()

func set_paused(paused: bool) -> void:
	if _active_wrld_form_id == -1 or paused == _paused:
		return
	if paused:
		_cancel_current_generation()
		_ready_collision_centers.clear()
	_paused = paused
	visible = not paused
	if terrain != null:
		terrain.visible = not paused
		terrain.set_physics_process(not paused)
		terrain.set_collision_mode(Terrain3DCollision.DISABLED if paused else Terrain3DCollision.DYNAMIC_GAME)
	if grass != null:
		if paused:
			grass.set_enabled(false)
		else:
			grass.set_enabled(true, false)
	if paused:
		for location: Vector2i in _region_states:
			if _region_states[location] in ["queued", "preparing", "prepared"]:
				_region_states[location] = "cancelled"
		_prepared_regions.clear()
		var paused_entry := _capture_active_entry()
		paused_entry["active"] = false
		_worldspace_entries[_active_wrld_form_id] = paused_entry
	else:
		_generation += 1
		_bind_camera()
		if terrain != null:
			terrain.collision.update(true)
		if _catalogue.is_empty() and not _catalogue_failed:
			_start_catalogue_job()
		else:
			_update_grass_coverage()
			_requeue_uncommitted_regions()
			_ensure_worker_pool()
			_check_streaming()
		var resumed_entry := _capture_active_entry()
		resumed_entry["active"] = true
		_worldspace_entries[_active_wrld_form_id] = resumed_entry
	state_changed.emit()

func request_terrain_priority(coord: Vector2i) -> void:
	if _active_wrld_form_id == -1 or _paused:
		return
	_desired_cells[coord] = true
	for location in _regions_for_cell(coord):
		if _region_states.get(location) == "queued":
			_priority_hints[location] = coord # Reprioritizes the existing entry; never duplicates it.
	if is_active() and not _paused and _catalogue.is_empty() and not _catalogue_failed and _workers.is_empty():
		_start_catalogue_job()
	# WorldStreamer can submit hundreds of hints in one tick. Dispatch is
	# intentionally deferred to TerrainStreamer's process pass, where all hints
	# are present and the region queue is ranked exactly once.

func await_ready_for(worldspace_form_id: int, coord: Vector2i, generation: int) -> ReadyStatus:
	if generation == _generation and worldspace_form_id == _active_wrld_form_id and _ready_collision_centers.has(coord):
		return ReadyStatus.READY
	if generation == _generation and worldspace_form_id == _active_wrld_form_id and _terrain_unavailable:
		# No authored LAND was found (or the selected master could not be opened).
		# Terrain has no collision to wait for, so release the transition after a
		# physics frame rather than leaving the player frozen indefinitely.
		await get_tree().physics_frame
		if _cancelled_generations.has(generation):
			return ReadyStatus.CANCELLED
		if generation != _generation or worldspace_form_id != _active_wrld_form_id:
			return ReadyStatus.SUPERSEDED
		_ready_collision_centers[coord] = true
		return ReadyStatus.READY
	while true:
		if _cancelled_generations.has(generation):
			return ReadyStatus.CANCELLED
		if generation != _generation or worldspace_form_id != _active_wrld_form_id:
			return ReadyStatus.SUPERSEDED
		if _is_collision_area_committed(coord):
			_bind_camera()
			terrain.collision.update(true)
			await get_tree().physics_frame
			if _cancelled_generations.has(generation):
				return ReadyStatus.CANCELLED
			if generation != _generation or worldspace_form_id != _active_wrld_form_id:
				return ReadyStatus.SUPERSEDED
			_ready_collision_centers[coord] = true
			return ReadyStatus.READY
		await state_changed
	return ReadyStatus.SUPERSEDED

func get_generation() -> int:
	return _generation

func is_active() -> bool:
	return _active_wrld_form_id != -1

func is_paused() -> bool:
	return _paused

func get_diagnostics() -> Dictionary:
	var retained_entries: Dictionary = {}
	for worldspace_id: int in _worldspace_entries:
		var entry: Dictionary = _worldspace_entries[worldspace_id]
		var entry_terrain := entry.get("terrain") as Terrain3D
		var entry_grass := entry.get("grass") as TerrainGrassParticles
		var entry_committed: Dictionary = entry.get("committed_regions", {})
		var entry_pool := entry.get("texture_pool") as Terrain3DTexturePool
		retained_entries[worldspace_id] = {
			"cache_family": entry.get("cache_family", ""), "active": bool(entry.get("active", false)),
			"catalogue_ready": not entry.get("catalogue", {}).is_empty() and not bool(entry.get("catalogue_failed", false)),
			"catalogue_error": String(entry.get("catalogue_error", "")),
			"committed_regions": entry_committed.size(),
			"texture_slots_used": entry_pool.used_slot_count() if entry_pool != null else 0,
			"terrain_visible": entry_terrain.visible if entry_terrain != null else false,
			"terrain_physics": entry_terrain.is_physics_processing() if entry_terrain != null else false,
			"collision_mode": entry_terrain.get_collision_mode() if entry_terrain != null else Terrain3DCollision.DISABLED,
			"grass_processing": entry_grass.is_processing() if entry_grass != null else false,
			"grass_emitters": entry_grass._emitters.size() if entry_grass != null else 0,
			"grass_coverage_updates": entry_grass.diagnostic_coverage_update_count if entry_grass != null else 0,
			"emitting_emitters": _count_emitting_emitters(entry_grass),
			"idle_stagers": (entry.get("idle_stagers", []) as Array).size(),
			"collision_updates": int(entry.get("collision_updates", 0)),
		}
	return {
		"active": is_active(), "paused": _paused, "worldspace_form_id": _active_wrld_form_id,
		"generation": _generation, "resident_cells": _resident.size(), "resident_coords": _resident.keys(),
		"queued_cells": _count_region_state("queued") + _count_region_state("preparing") + _count_region_state("prepared"),
		"idle_stagers": _idle_stagers.size(),
		"empty_cells": 0, "catalogue_ready": not _catalogue.is_empty() and not _catalogue_failed,
		"catalogue_error": _catalogue_error,
		"committed_regions": _committed_regions.size(), "committed_region_locations": _committed_regions.keys(),
		"total_regions": _touched_regions.size(), "logical_slots": _logical_slots.duplicate(),
		"region_states": _region_states.duplicate(), "worker_count": _worker_count,
		"queued_regions": _count_region_state("queued"), "preparing_regions": _count_region_state("preparing"),
		"prepared_regions": _count_region_state("prepared"),
		"abandoned_workers": _abandoned_tasks.size(),
		"terrain_ms": diagnostic_terrain_ms.duplicate(),
		"staging_ms": diagnostic_staging_ms.duplicate(),
		"publication_ms": diagnostic_publication_ms.duplicate(),
		"collision_updates": diagnostic_collision_updates,
		"cache_family": _cache_family_by_worldspace.get(_active_wrld_form_id, ""),
		"retained_worldspaces": retained_entries,
		"texture_slots_used": texture_pool.used_slot_count() if texture_pool != null else 0,
		"texture_entries": texture_pool.get_debug_texture_list() if texture_pool != null else [],
	}

func _count_emitting_emitters(entry_grass: TerrainGrassParticles) -> int:
	if entry_grass == null:
		return 0
	var emitting := 0
	for record: Dictionary in entry_grass._emitters.values():
		if (record["node"] as GPUParticles3D).emitting:
			emitting += 1
	return emitting

func _process(delta: float) -> void:
	_poll_workers()
	if not is_active() or _paused:
		return
	_publish_prepared_regions()
	_check_timer -= delta
	if _check_timer <= 0.0:
		_check_timer = CHECK_INTERVAL_SEC
		_check_streaming()
	_dispatch_available_workers()

func _cancel_current_generation() -> void:
	_cancelled_generations[_generation] = true
	_generation += 1

func _active_camera() -> Camera3D:
	return get_viewport().get_camera_3d() if get_viewport() != null else null

func _bind_camera() -> void:
	if terrain != null:
		terrain.set_camera(_active_camera())

func _current_grid_coord() -> Variant:
	var camera := _active_camera()
	if camera == null:
		return null
	return Vector2i(floori(camera.global_position.x / CELL_SIZE_METERS), floori(-camera.global_position.z / CELL_SIZE_METERS))

static func _within_radius(dx: int, dy: int, radius: float) -> bool:
	return dx * dx + dy * dy <= radius * radius

func _check_streaming() -> void:
	var center: Variant = _current_grid_coord()
	if center == null:
		return
	var center_changed: bool = center != _last_center
	_last_center = center
	_bind_camera()
	_desired_cells.clear()
	var bound := ceili(load_radius)
	for dx in range(-bound, bound + 1):
		for dy in range(-bound, bound + 1):
			if not _within_radius(dx, dy, load_radius):
				continue
			var coord: Vector2i = center + Vector2i(dx, dy)
			_desired_cells[coord] = true
	if center_changed:
		_update_grass_coverage()

func _start_catalogue_job() -> void:
	if not _workers.is_empty():
		return
	var configuration := GameDataConfigScript.resolve()
	var esm_path := String(configuration.get("data_dir", "")) + GameDataConfigScript.ESM_FILE
	var holder := [{}]
	var worldspace := _active_wrld_form_id
	var generation := _generation
	_indexing = true
	var task := WorkerThreadPool.add_task(func() -> void:
		var stager := TerrainRegionStager.new()
		if not stager.open_esm(esm_path):
			holder[0] = {"error": stager.get_last_error()}
			return
		holder[0] = {"stager": stager, "catalogue": stager.index_worldspace(worldspace)}
	)
	_workers.append({"task": task, "holder": holder, "generation": generation, "region": Vector2i.ZERO, "kind": "catalogue", "stager_pool": _idle_stagers})

func _poll_workers() -> void:
	for abandoned: Dictionary in _abandoned_tasks.duplicate():
		var task_id := int(abandoned.task)
		if WorkerThreadPool.is_task_completed(task_id):
			WorkerThreadPool.wait_for_task_completion(task_id)
			_abandoned_tasks.erase(abandoned)
			var payload: Dictionary = abandoned.holder[0]
			if payload.has("stager"):
				(abandoned.stager_pool as Array).append(payload.stager)
	for worker: Dictionary in _workers.duplicate():
		var task_id := int(worker.task)
		if not WorkerThreadPool.is_task_completed(task_id):
			continue
		WorkerThreadPool.wait_for_task_completion(task_id)
		_workers.erase(worker)
		var payload: Dictionary = worker.holder[0]
		var task_generation := int(worker.generation)
		if payload.has("stager"):
			(worker.stager_pool as Array).append(payload.stager)
		if task_generation != _generation or not is_active() or _paused:
			continue
		if not String(payload.get("error", "")).is_empty():
			if String(worker.kind) == "catalogue":
				_finish_catalogue({"catalogue": {"error": String(payload.error)}})
			else:
				push_error("TerrainStreamer worker: " + String(payload.error))
			state_changed.emit()
			continue
		if String(worker.kind) == "catalogue":
			_finish_catalogue(payload)
		elif String(worker.kind) == "pool_init":
			pass
		else:
			var location: Vector2i = worker.region
			payload.erase("stager")
			diagnostic_staging_ms.append(float(Time.get_ticks_usec() - int(worker.started_us)) / 1000.0)
			_region_states[location] = "prepared"
			_prepared_regions.append({"location": location, "payload": payload, "generation": task_generation})
	if is_active() and not _paused and _catalogue.is_empty() and not _catalogue_failed and _workers.is_empty():
		_start_catalogue_job()
	else:
		_dispatch_available_workers()

func _finish_catalogue(payload: Dictionary) -> void:
	_indexing = false
	_catalogue = payload.get("catalogue", {})
	_catalogue_failed = false
	_catalogue_error = ""
	if not String(_catalogue.get("error", "")).is_empty():
		_catalogue_error = String(_catalogue.error)
		_catalogue = {}
		_catalogue_failed = true
		_terrain_unavailable = true
		push_error("TerrainStreamer catalogue: " + _catalogue_error)
		state_changed.emit()
		return
	for cell: Dictionary in _catalogue.get("usable_cells", []):
		_usable_cells[cell.coord] = int(cell.cell_form_id)
	for location: Vector2i in _catalogue.get("regions", []):
		_touched_regions[location] = true
		_region_states[location] = "unseen"
		_region_cells[location] = []
	_terrain_unavailable = _touched_regions.is_empty()
	for coord: Vector2i in _usable_cells:
		for location in _regions_for_cell(coord):
			(_region_cells[location] as Array).append(coord)
	var ids: PackedInt64Array = _catalogue.get("ltex_form_ids", PackedInt64Array())
	for i in range(ids.size()):
		_logical_slots[int(ids[i])] = i + 1
	grass.discover_catalogue(ids)
	var init_error := terrain.data.initialize_fixed_region_domain(_catalogue.get("region_domain", []))
	if init_error != OK:
		push_error("TerrainStreamer fixed-domain initialization failed: %s" % init_error)
		return
	_worker_count = clampi(OS.get_processor_count() - 1, 1, MAX_WORKERS)
	_ensure_worker_pool()
	_requeue_uncommitted_regions()
	_check_streaming()
	state_changed.emit()

func _requeue_uncommitted_regions() -> void:
	for location: Vector2i in _touched_regions:
		if not _committed_regions.has(location):
			_region_states[location] = "queued"

func _dispatch_available_workers() -> void:
	if _paused or _catalogue.is_empty():
		return
	while not _idle_stagers.is_empty():
		var location: Variant = _take_next_region()
		if location == null:
			break
		_start_region_job(location)

func _take_next_region() -> Variant:
	var center: Variant = _last_center
	var near: Array[Vector2i] = []
	var far: Array[Vector2i] = []
	for location: Vector2i in _region_states:
		if _region_states[location] != "queued":
			continue
		(far if not _priority_hints.has(location) and (center == null or _region_distance_cells(location, center) > load_radius) else near).append(location)
	near.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return _region_priority_score(a, center) < _region_priority_score(b, center))
	far.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return _region_distance_cells(a, center) < _region_distance_cells(b, center))
	_dispatch_count += 1
	if not far.is_empty() and (_dispatch_count % FAR_SLOT_INTERVAL == 0 or near.is_empty()):
		return far[0]
	if not near.is_empty():
		return near[0]
	return far[0] if not far.is_empty() else null

func _region_distance_cells(location: Vector2i, center: Variant) -> float:
	if center == null:
		return INF
	var best := INF
	for coord: Vector2i in _region_cells.get(location, []):
		best = minf(best, Vector2(coord - center).length())
	return best

func _region_priority_score(location: Vector2i, center: Variant) -> float:
	if _priority_hints.has(location):
		return -1.0
	return _region_distance_cells(location, center)

func _start_region_job(location: Vector2i) -> void:
	_region_states[location] = "preparing"
	_priority_hints.erase(location)
	var holder := [{}]
	var stager: TerrainRegionStager = _idle_stagers.pop_back()
	var worldspace := _active_wrld_form_id
	var slots := _logical_slots.duplicate()
	var generation := _generation
	var task := WorkerThreadPool.add_task(func() -> void:
		holder[0] = stager.compose_region(worldspace, location, slots)
		holder[0]["stager"] = stager
	)
	_workers.append({"task": task, "holder": holder, "generation": generation, "region": location, "kind": "compose", "started_us": Time.get_ticks_usec(), "stager_pool": _idle_stagers})

func _ensure_worker_pool() -> void:
	if _catalogue.is_empty() or _paused:
		return
	var assigned := _idle_stagers.size()
	for worker: Dictionary in _workers:
		if String(worker.kind) in ["compose", "pool_init"]:
			assigned += 1
	var missing := maxi(_worker_count - assigned, 0)
	if missing > 0:
		_start_worker_pool_initialization(missing)

func _start_worker_pool_initialization(count: int) -> void:
	var configuration := GameDataConfigScript.resolve()
	var esm_path := String(configuration.get("data_dir", "")) + GameDataConfigScript.ESM_FILE
	var worldspace := _active_wrld_form_id
	var generation := _generation
	for unused in range(count):
		var holder := [{}]
		var task := WorkerThreadPool.add_task(func() -> void:
			var stager := TerrainRegionStager.new()
			if not stager.open_esm(esm_path):
				holder[0] = {"error": stager.get_last_error()}
				return
			var indexed := stager.index_worldspace(worldspace)
			var error := String(indexed.get("error", ""))
			holder[0] = {"stager": stager, "error": error}
		)
		_workers.append({"task": task, "holder": holder, "generation": generation, "region": Vector2i.ZERO, "kind": "pool_init", "stager_pool": _idle_stagers})

func _publish_prepared_regions() -> void:
	for unused in range(mini(regions_per_frame, _prepared_regions.size())):
		var prepared: Dictionary = _prepared_regions.pop_front()
		if int(prepared.generation) != _generation:
			continue
		if not _publish_worker_region(prepared.payload, prepared.location):
			_prepared_regions.append(prepared)

func _abandon_workers() -> void:
	for worker: Dictionary in _workers:
		_abandoned_tasks.append({
			"task": int(worker.task),
			"holder": worker.holder,
			"stager_pool": _idle_stagers,
		})
	_workers.clear()

func _count_region_state(state: String) -> int:
	var count := 0
	for value: String in _region_states.values():
		if value == state:
			count += 1
	return count

func _publish_worker_region(payload: Dictionary, location: Vector2i) -> bool:
	if not String(payload.get("error", "")).is_empty():
		push_error("TerrainStreamer compose %s: %s" % [location, payload.error])
		_region_states[location] = "cancelled"
		return true
	var started_us := Time.get_ticks_usec()
	if not bridge.prepare_logical_slots(terrain, payload.get("used_ltex_form_ids", PackedInt64Array()), _logical_slots):
		# Slot resolution is a deterministic main-thread operation. A false
		# result is therefore a permanent publication failure, not a transient
		# worker/resource condition; consuming the payload prevents a retry loop.
		push_error("TerrainStreamer: cancelling region %s after permanent logical texture-slot failure" % location)
		_region_states[location] = "cancelled"
		state_changed.emit()
		return true
	var publish_started_us := Time.get_ticks_usec()
	var publish_error := terrain.data.publish_region_maps(location, payload.get("maps", []))
	diagnostic_publication_ms.append(float(Time.get_ticks_usec() - publish_started_us) / 1000.0)
	if publish_error != OK:
		push_error("TerrainStreamer publish %s failed: %s" % [location, publish_error])
		_region_states[location] = "cancelled"
		return true
	_committed_regions[location] = true
	_region_states[location] = "committed"
	# A cell can depend on more than the region that just published, so update
	# the whole bounded diagnostic/readiness set when any dependency closes.
	for coord: Vector2i in _desired_cells:
		if _usable_cells.has(coord) and _cell_is_committed(coord):
			_resident[coord] = int(_usable_cells[coord])
	_update_grass_coverage()
	if _region_intersects_collision_area(location):
		terrain.collision.update(true)
		diagnostic_collision_updates += 1
	diagnostic_terrain_ms.append(float(Time.get_ticks_usec() - started_us) / 1000.0)
	state_changed.emit()
	return true

func _region_intersects_collision_area(location: Vector2i) -> bool:
	if terrain == null or _last_center == null:
		return false
	var collision_radius_cells := float(terrain.collision_radius) / CELL_SIZE_METERS
	return _region_distance_cells(location, _last_center) <= collision_radius_cells

func _update_grass_coverage() -> void:
	if grass == null or _last_center == null:
		return
	var cells: Array[Dictionary] = []
	var bound := ceili(load_radius)
	for dx in range(-bound, bound + 1):
		for dy in range(-bound, bound + 1):
			if not _within_radius(dx, dy, load_radius):
				continue
			var coord: Vector2i = _last_center + Vector2i(dx, dy)
			if _usable_cells.has(coord) and _cell_is_committed(coord):
				cells.append({"cell_form_id": int(_usable_cells[coord]), "coord": coord})
	grass.update_coverage(_last_center, cells)

func _regions_for_cell(coord: Vector2i) -> Array[Vector2i]:
	var output: Array[Vector2i] = []
	if not _usable_cells.has(coord):
		return output
	var x0 := coord.x * 32
	var x1 := x0 + 32
	var z0 := -32 * (coord.y + 1)
	var z1 := -32 * coord.y
	for rx in [_floor_div(x0, 256), _floor_div(x1, 256)]:
		for ry in [_floor_div(z0, 256), _floor_div(z1, 256)]:
			var location := Vector2i(rx, ry)
			if _touched_regions.has(location) and not output.has(location):
				output.append(location)
	return output

func _cell_is_committed(coord: Vector2i) -> bool:
	var regions := _regions_for_cell(coord)
	return not regions.is_empty() and regions.all(func(location: Vector2i) -> bool: return _committed_regions.has(location))

static func _floor_div(value: int, divisor: int) -> int:
	var quotient := value / divisor
	var remainder := value % divisor
	if remainder != 0 and ((remainder < 0) != (divisor < 0)):
		quotient -= 1
	return quotient

func _is_collision_area_committed(center: Vector2i) -> bool:
	if terrain == null or bridge == null or texture_pool == null or _paused or _catalogue.is_empty():
		return false
	var collision_radius_cells := float(terrain.collision_radius) / CELL_SIZE_METERS
	var collision_cells := ceili(collision_radius_cells)
	for dx in range(-collision_cells, collision_cells + 1):
		for dy in range(-collision_cells, collision_cells + 1):
			if not _within_radius(dx, dy, collision_radius_cells):
				continue
			var coord := center + Vector2i(dx, dy)
			if not _usable_cells.has(coord):
				continue
			if not _cell_is_committed(coord):
				return false
	return true
