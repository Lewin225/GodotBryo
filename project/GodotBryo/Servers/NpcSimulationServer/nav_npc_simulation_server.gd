extends Node

## Simulates placed actors outside the loaded world. Autoloaded as
## NpcSimulationServer. seed() loads the whole game's authored NAVM data through
## [NavmeshReader], indexes every placed actor and XTEL door, and grounds each
## actor against the navmesh; it runs only when called.
##
## Two layers, deliberately kept distinct because their confidence levels
## differ:
##
## - The triangle mesh, and adjacency WITHIN a NAVM record, are authored data.
##   Positions and routes derived from them are as good as the ESM.
## - Which records connect to which is also authored (NVEX). Where exactly the
##   crossing happens between two records is NOT authored and is derived
##   geometrically in the native layer; see NavmeshDatabase's cross-record
##   stitch. Routes are therefore exact within a record and approximate at
##   record seams.
##
## NAVM centers are a query optimiser only. `use_coarse_index` toggles the
## authored-bounds broad-phase; it changes query cost, never the answer (the
## test asserts both paths agree). It must never become a source of
## connectivity: two records whose bounds are adjacent are not connected unless
## NVEX says so, which is what stops a route hopping across a river.

signal seed_progress(status: String, completed: int, total: int)
signal seed_finished
signal route_ready(request_id: int, result: Dictionary)
signal cross_space_route_ready(request_id: int, result: Dictionary)
signal door_sequence_ready(request_id: int, portals: Array)

const NpcPortalScript := preload("res://GodotBryo/Servers/NpcSimulationServer/npc_portal.gd")
const GameDataConfigScript := preload("res://game_data_config.gd")

## Plugins whose NAVM records are loaded. Their navmesh graphs are
## self-contained: across the base game alone and all six masters together, zero
## NVEX links resolve outside their own file, so this list can grow or shrink
## without breaking connectivity.
const PLUGIN_FILES := [
	"FalloutNV.esm", "DeadMoney.esm", "HonestHearts.esm",
	"OldWorldBlues.esm", "LonesomeRoad.esm", "GunRunnersArsenal.esm",
]

## After a route comes back not found, the same target is not asked for
## again for this many seconds (NpcController, LowLevelTravel).
@export var route_retry_seconds := 5.0

## Max distance an actor may be from the navmesh and still be considered
## groundable, in meters.
@export var ground_snap_radius := 8.0
## Toggles the authored-NVGD-bounds broad-phase. False forces every query to
## test every triangle in the space -- same answer, far slower.
@export var use_coarse_index := true
@export_range(1, 1024, 1) var records_per_frame := 32

var navmesh: NavmeshReader
## Child node holding Godot navigation for the cells the streamers have
## loaded, for physicalised actors' local pathing. Filled once the navmesh has
## loaded; cells made local before then are built when it has.
var local_navigation := LocalNavigation.new()
## Child node running actors' active packages (AddScriptPackage).
var package_runner := PackageRunner.new()
## Child node moving the actors this server owns toward their move_target.
var low_level_travel := LowLevelTravel.new()
## This server's own background thread for off-screen route work.
var worker := NpcSimulationWorker.new()
## Child node printing a periodic debug line (DebugNpcLog).
var debug_log := NpcDebugLog.new()
## Request ids cancel_request() marked, which the simulation thread skips;
## shared with that thread under `_cancel_mutex`.
var _cancelled_requests: Dictionary = {}
var _cancel_mutex := Mutex.new()
var actors_by_instance_id: Dictionary = {}
var actors_by_space_form_id: Dictionary = {}
var actors_by_cell_form_id: Dictionary = {}
## instance_id -> {position, distance, navmesh_form_id, global_triangle}. Only
## actors that actually snapped appear here.
var grounding_by_instance_id: Dictionary = {}
var portals: Array = []
## Load doors with lock data (XLOC), each once: the ones `blocked_doors_for`
## checks.
var lockable_doors: Array[DoorReference] = []
## space_form_id -> Array[NpcPortal] leaving that space. Portals are stored
## directed (source -> destination); a real door's other side is its own
## authored XTEL record, so traversing this directed graph finds genuine door
## pairs rather than assuming every door is two-way.
var portals_by_source_space: Dictionary = {}
## component -> Array[NpcPortal] leaving that connected walkable region, and
## component -> space it belongs to.
##
## Routing is keyed on COMPONENT, not space, because a space is not one walkable
## region: the exterior worldspace alone splits into 181 disconnected components
## holding 2.42% of its triangles. NCR Correctional Facility is one -- an
## exterior yard inside a fence whose only link to the rest of the Mojave is
## through a building. Space-keyed routing treated that as "same space, just walk
## there", found no path, and fell back to a straight line through the fence.
var portals_by_source_component: Dictionary = {}
var space_by_component: Dictionary = {}
var status := "Waiting for EsmServer"
var is_seeded := false
var navmesh_load_stats: Dictionary = {}

var _load_thread: Thread
var _next_request_id := 1

var _indexed_space_by_instance_id: Dictionary = {}

func _ready() -> void:
	local_navigation.name = "LocalNavigation"
	add_child(local_navigation)
	package_runner.name = "PackageRunner"
	add_child(package_runner)
	low_level_travel.name = "LowLevelTravel"
	add_child(low_level_travel)
	debug_log.name = "NpcDebugLog"
	add_child(debug_log)
	worker.start()
	var esm_server := get_tree().root.get_node_or_null("EsmServer")
	if esm_server != null:
		esm_server.reference_cell_changed.connect(_on_reference_cell_changed)

func _exit_tree() -> void:
	# Same hazard EsmServer documents: destroying a running Thread aborts the
	# process, so a session quitting mid-load must wait for the read rather than
	# crash after its tests have already passed.
	if _load_thread != null and _load_thread.is_started():
		_load_thread.wait_to_finish()
	_load_thread = null
	worker.stop()

func seed() -> void:
	if is_seeded:
		return
	var esm_server := get_tree().root.get_node_or_null("EsmServer")
	if esm_server == null:
		status = "EsmServer is unavailable"
		seed_progress.emit(status, 0, 0)
		return
	if not esm_server.is_ready():
		status = "Waiting for EsmServer"
		seed_progress.emit(status, 0, 0)
		await esm_server.esm_ready

	actors_by_instance_id.clear()
	actors_by_space_form_id.clear()
	actors_by_cell_form_id.clear()
	_indexed_space_by_instance_id.clear()
	grounding_by_instance_id.clear()
	portals.clear()
	lockable_doors.clear()
	portals_by_source_space.clear()
	portals_by_source_component.clear()
	space_by_component.clear()

	status = "Loading navmesh"
	seed_progress.emit(status, 0, 0)
	if not await _load_navmesh():
		status = "Navmesh unavailable"
		seed_progress.emit(status, 0, 0)
		return

	var actor_count: int = esm_server.get_all_placed_actor_instance_ids().size()
	await _seed_actors(esm_server, actor_count)
	var door_count: int = esm_server.get_all_xtel_door_instance_ids().size()
	await _seed_portals(esm_server, door_count)

	status = "Ready"
	is_seeded = true
	seed_progress.emit(status, actors_by_instance_id.size() + portals.size(), actor_count + door_count)
	seed_finished.emit()

## The whole-game navmesh load is a bounded read measured at ~0.36 s, but it is
## still done off the main thread so boot stays responsive.
func _load_navmesh() -> bool:
	if ClassDB.class_exists("NavmeshReader"):
		_load_thread = Thread.new()
		_load_thread.start(_load_navmesh_background)
		while _load_thread.is_alive():
			await get_tree().process_frame
		var result: Dictionary = _load_thread.wait_to_finish()
		_load_thread = null
		if not bool(result.get("ok", false)):
			push_error("NavNpcSimulationServer: %s" % String(result.get("error", "navmesh load failed")))
			return false
		navmesh = result["reader"]
		navmesh_load_stats = navmesh.get_load_stats()
		local_navigation.set_navmesh(navmesh)
		return true
	# A stale project/bin/*.so predating this class does not fail loudly on its
	# own -- it just makes the whole navmesh silently absent. Say so.
	push_error("NavmeshReader is unavailable. Rebuild the GDExtension (see AGENTS.md).")
	return false

func _load_navmesh_background() -> Dictionary:
	var reader = ClassDB.instantiate("NavmeshReader")
	if reader == null:
		return {"ok": false, "error": "NavmeshReader class is unavailable"}
	var config := GameDataConfigScript.resolve()
	var data_dir := String(config.get("data_dir", ""))
	if data_dir == "":
		return {"ok": false, "error": String(config.get("error", "game data directory not found"))}
	var paths := PackedStringArray()
	for plugin_file in PLUGIN_FILES:
		var full_path: String = data_dir + plugin_file
		if FileAccess.file_exists(full_path):
			paths.append(full_path)
	if paths.is_empty():
		return {"ok": false, "error": "No plugins found in %s" % data_dir}
	if not reader.load_plugins(paths):
		return {"ok": false, "error": reader.get_last_error()}
	return {"ok": true, "reader": reader}

func _seed_actors(esm_server, total: int) -> void:
	status = "Seeding actors"
	var completed := 0
	while completed < total:
		for actor: ActorReference in esm_server.get_placed_actor_reference_batch(completed, records_per_frame):
			if actor != null:
				_index_actor(actor)
		completed = min(completed + records_per_frame, total)
		seed_progress.emit(status, completed, total)
		if completed < total:
			await get_tree().process_frame

func _seed_portals(esm_server, total: int) -> void:
	status = "Seeding portals"
	var completed := 0
	while completed < total:
		for door: DoorReference in esm_server.get_xtel_door_reference_batch(completed, records_per_frame):
			var destination_space: int = door.get_teleport_destination_space_form_id() if door != null and door.has_teleport else 0
			if destination_space != 0:
				var portal = NpcPortalScript.new()
				portal.source_reference = door
				portal.source_space_form_id = door.current_space_form_id
				portal.source_position = door.position
				portal.destination_space_form_id = destination_space
				portal.destination_position = door.teleport_position
				portals.append(portal)
				if door.is_locked or door.lock_key_form_id != 0:
					lockable_doors.append(door)
				if not portals_by_source_space.has(portal.source_space_form_id):
					portals_by_source_space[portal.source_space_form_id] = []
				portals_by_source_space[portal.source_space_form_id].append(portal)
				_index_portal_components(portal)
		completed = min(completed + records_per_frame, total)
		seed_progress.emit(status, completed, total)
		if completed < total:
			await get_tree().process_frame

## Resolves which walkable region each end of a door touches. A door is the only
## thing that joins two components, so this is what makes an enclosed yard
## reachable at all.
func _index_portal_components(portal) -> void:
	var source: Dictionary = navmesh.snap(portal.source_space_form_id, portal.source_position, ground_snap_radius * 4.0, use_coarse_index)
	var destination: Dictionary = navmesh.snap(portal.destination_space_form_id, portal.destination_position, ground_snap_radius * 4.0, use_coarse_index)
	if not bool(source.get("found", false)) or not bool(destination.get("found", false)):
		return
	portal.source_component = int(source["component"])
	portal.destination_component = int(destination["component"])
	space_by_component[portal.source_component] = portal.source_space_form_id
	space_by_component[portal.destination_component] = portal.destination_space_form_id
	if not portals_by_source_component.has(portal.source_component):
		portals_by_source_component[portal.source_component] = []
	portals_by_source_component[portal.source_component].append(portal)

## The walkable region containing a point, or -1 when it is not on navmesh.
func get_component_at(space_form_id: int, position: Vector3, radius := 0.0) -> int:
	if navmesh == null:
		return -1
	var hit: Dictionary = navmesh.snap(space_form_id, position, radius if radius > 0.0 else ground_snap_radius, use_coarse_index)
	return int(hit["component"]) if bool(hit.get("found", false)) else -1

func _index_actor(actor: ActorReference) -> void:
	actors_by_instance_id[actor.instance_id] = actor
	_indexed_space_by_instance_id[actor.instance_id] = actor.current_space_form_id
	_add_to_index(actors_by_space_form_id, actor.current_space_form_id, actor)
	_add_to_index(actors_by_cell_form_id, actor.current_cell_form_id, actor)
	var grounding := ground(actor)
	if not grounding.is_empty():
		grounding_by_instance_id[actor.instance_id] = grounding
	package_runner.track(actor)

func _add_to_index(index: Dictionary, key: int, actor: ActorReference) -> void:
	if not index.has(key):
		index[key] = {}
	index[key][actor.instance_id] = actor

func _remove_from_index(index: Dictionary, key: int, actor: ActorReference) -> void:
	if index.has(key):
		(index[key] as Dictionary).erase(actor.instance_id)

## Keeps a tracked actor's space and cell index, and its grounding, in step
## with where it is.
func _on_reference_cell_changed(reference: EsmReference, old_cell_form_id: int, new_cell_form_id: int) -> void:
	var actor := reference as ActorReference
	if actor == null or not _is_tracked(actor):
		return
	_remove_from_index(actors_by_cell_form_id, old_cell_form_id, actor)
	_add_to_index(actors_by_cell_form_id, new_cell_form_id, actor)
	var old_space := int(_indexed_space_by_instance_id.get(actor.instance_id, 0))
	if old_space != actor.current_space_form_id:
		_remove_from_index(actors_by_space_form_id, old_space, actor)
		_add_to_index(actors_by_space_form_id, actor.current_space_form_id, actor)
		_indexed_space_by_instance_id[actor.instance_id] = actor.current_space_form_id
	var grounding := ground(actor)
	if grounding.is_empty():
		grounding_by_instance_id.erase(actor.instance_id)
	else:
		grounding_by_instance_id[actor.instance_id] = grounding

## Where this actor would actually stand, as opposed to where the ESM places
## them. Empty when no navmesh lies within `ground_snap_radius`, which is a real
## outcome (not every cell is navmeshed, and some authored placements genuinely
## sit off-mesh) rather than an error.
func ground(actor: ActorReference) -> Dictionary:
	if navmesh == null or actor == null:
		return {}
	var result: Dictionary = navmesh.snap(actor.current_space_form_id, actor.position, ground_snap_radius, use_coarse_index)
	if not bool(result.get("found", false)):
		return {}
	return result

func is_grounded(actor: ActorReference) -> bool:
	return actor != null and grounding_by_instance_id.has(actor.instance_id)

## The position to physicalize at: the navmesh point, not the authored one.
func get_ground_position(actor: ActorReference) -> Vector3:
	var grounding: Dictionary = grounding_by_instance_id.get(actor.instance_id, {})
	return grounding.get("position", actor.position) if not grounding.is_empty() else actor.position

func get_actors_in_space(space_form_id: int) -> Array[ActorReference]:
	return _actors_from_index(actors_by_space_form_id.get(space_form_id, {}))

func get_actors_in_cell(cell_form_id: int) -> Array[ActorReference]:
	return _actors_from_index(actors_by_cell_form_id.get(cell_form_id, {}))

## Straight-line range over grounded positions where available. This is a
## proximity test, not a reachability test -- two actors on opposite banks of a
## river are close here and still not connected. Use [method request_route] when
## reachability is what matters.
func get_actors_in_range(space_form_id: int, center: Vector3, radius: float) -> Array[ActorReference]:
	var result: Array[ActorReference] = []
	var squared_radius := radius * radius
	for actor in get_actors_in_space(space_form_id):
		if get_ground_position(actor).distance_squared_to(center) <= squared_radius:
			result.append(actor)
	return result

func _actors_from_index(bucket: Dictionary) -> Array[ActorReference]:
	var result: Array[ActorReference] = []
	for actor in bucket.values():
		result.append(actor as ActorReference)
	return result

## Blocking route. Safe to call from a worker thread: NavmeshReader holds no
## file handle once loaded and every query on it is read-only, so one instance
## serves any number of threads (unlike EsmReader, which needs one per thread).
func route(space_form_id: int, from: Vector3, to: Vector3) -> Dictionary:
	if navmesh == null:
		return {"found": false}
	return navmesh.find_route(space_form_id, from, to, ground_snap_radius, use_coarse_index)

## Async route. Returns a request id; the result arrives on [signal route_ready].
## Low-level simulation is never blocked on this -- a route is computed once and
## the actor keeps moving on its previous one until the new one lands.
## Runs on this server's own thread (`worker`); an `on_screen` route (an
## NpcController's) is taken before every off-screen job.
func request_route(space_form_id: int, from: Vector3, to: Vector3, on_screen := false) -> int:
	var request_id := _next_request_id
	_next_request_id += 1
	if navmesh == null:
		route_ready.emit.call_deferred(request_id, {"found": false})
		return request_id
	worker.post(_run_route_task.bind(request_id, space_form_id, from, to), on_screen)
	return request_id

## Marks a route or door-sequence request queued on the simulation thread so
## the thread skips it; its result never arrives. For a request whose answer is
## no longer wanted (the actor's target moved on).
func cancel_request(request_id: int) -> void:
	_cancel_mutex.lock()
	_cancelled_requests[request_id] = true
	_cancel_mutex.unlock()

## Whether `request_id` was cancelled, forgetting the mark.
func _take_cancelled(request_id: int) -> bool:
	_cancel_mutex.lock()
	var cancelled := _cancelled_requests.erase(request_id)
	_cancel_mutex.unlock()
	return cancelled

func _run_route_task(request_id: int, space_form_id: int, from: Vector3, to: Vector3) -> void:
	if _take_cancelled(request_id):
		return
	var result := route(space_form_id, from, to)
	_finish_route.call_deferred(request_id, result)

func _finish_route(request_id: int, result: Dictionary) -> void:
	# A cancel that came after the job ran is forgotten, and the result is not
	# delivered.
	if _take_cancelled(request_id):
		return
	route_ready.emit(request_id, result)

## Finds a sequence of authored XTEL portals leading from one space to another,
## breadth-first over [member portals_by_source_space].
##
## BFS minimises the NUMBER OF DOORS, not distance walked. That is a deliberate
## simplification and a real limitation: the fewest-doors path is not necessarily
## the shortest one. It is honest about the authored data though -- an XTEL
## transition has no authored traversal cost to weigh against metres walked, so
## any distance-based comparison here would be inventing one.
func find_portal_path(from_space: int, to_space: int, max_doors := 8) -> Array:
	var paths := find_portal_paths(from_space, to_space, max_doors, 1)
	return paths[0] if not paths.is_empty() else []

## Door sequences between two SPACES, kept for callers that only know spaces.
## Prefer [method find_component_paths]: a space is not one walkable region.
func find_portal_paths(from_space: int, to_space: int, max_doors := 8, max_paths := 4, blocked_doors: Dictionary = {}) -> Array:
	if from_space == to_space:
		return [[]]
	var found: Array = []
	var queue: Array = [{"space": from_space, "path": [], "seen": {from_space: true}}]
	var expansions := 0
	while not queue.is_empty() and found.size() < max_paths and expansions < 20000:
		var node: Dictionary = queue.pop_front()
		var path: Array = node["path"]
		if path.size() >= max_doors:
			continue
		var seen: Dictionary = node["seen"]
		for portal in portals_by_source_space.get(node["space"], []):
			expansions += 1
			if blocked_doors.has(portal.source_reference):
				continue
			var next_space: int = portal.destination_space_form_id
			if seen.has(next_space):
				continue
			var next_path: Array = path.duplicate()
			next_path.append(portal)
			if next_space == to_space:
				found.append(next_path)
				if found.size() >= max_paths:
					break
				continue
			var next_seen: Dictionary = seen.duplicate()
			next_seen[next_space] = true
			queue.append({"space": next_space, "path": next_path, "seen": next_seen})
	return found

## Door sequences between two connected walkable REGIONS, shortest first.
##
## This is the search that matters. Unlike the space-level version it can return
## a non-empty path when both ends are in the same space, which is exactly the
## NCR Correctional Facility case: an exterior yard sealed behind a fence whose
## only route to the rest of the Mojave runs out through a building and back
## into the open. Space-level search called that "same space, no doors needed",
## found no walkable path, and produced a straight line through the fence.
func find_component_paths(from_component: int, to_component: int, max_doors := 8, max_paths := 4, blocked_doors: Dictionary = {}) -> Array:
	if from_component < 0 or to_component < 0:
		return []
	if from_component == to_component:
		return [[]]
	var found: Array = []
	var queue: Array = [{"component": from_component, "path": [], "seen": {from_component: true}}]
	var expansions := 0
	while not queue.is_empty() and found.size() < max_paths and expansions < 40000:
		var node: Dictionary = queue.pop_front()
		var path: Array = node["path"]
		if path.size() >= max_doors:
			continue
		var seen: Dictionary = node["seen"]
		for portal in portals_by_source_component.get(node["component"], []):
			expansions += 1
			if blocked_doors.has(portal.source_reference):
				continue
			var next_component: int = portal.destination_component
			if next_component < 0:
				continue
			var next_path: Array = path.duplicate()
			next_path.append(portal)
			# Test the goal BEFORE the cycle check, so a path that leaves a
			# region and comes back to its neighbour is still reachable.
			if next_component == to_component:
				found.append(next_path)
				if found.size() >= max_paths:
					break
				continue
			if seen.has(next_component):
				continue
			var next_seen: Dictionary = seen.duplicate()
			next_seen[next_component] = true
			queue.append({"component": next_component, "path": next_path, "seen": next_seen})
	return found

## A route that may cross spaces by walking to a door, passing through it, and
## continuing on the other side.
##
## Returns {found, legs, total_length, door_count, walkable}. Each leg is
## {space_form_id, from, to, waypoints, length, has_navmesh, exit_portal}.
## `exit_portal` is the door walked to at the end of that leg, or null on the
## final leg.
##
## `walkable` is false when any leg could not be routed on real navmesh -- most
## often because that space has no NAVM records at all. Such a leg is still
## returned, with has_navmesh false and a straight from/to pair, so a caller can
## see exactly where the path stops being real rather than being handed a
## confident-looking route with an invented middle.
func route_across_spaces(from_space: int, from_position: Vector3, to_space: int, to_position: Vector3) -> Dictionary:
	var result := {"found": false, "legs": [], "total_length": 0.0, "door_count": 0, "walkable": true}
	if navmesh == null:
		return result

	# Which walkable region each end is actually in. Same space is not the same
	# region, so this -- not the space id -- decides whether doors are needed.
	var from_component := get_component_at(from_space, from_position, ground_snap_radius * 4.0)
	var to_component := get_component_at(to_space, to_position, ground_snap_radius * 4.0)
	var portal_paths: Array = []
	if from_component >= 0 and to_component >= 0:
		portal_paths = find_component_paths(from_component, to_component)
	if portal_paths.is_empty():
		# Either end is off navmesh, or no door sequence joins the two regions.
		# Fall back to the space-level search so a caller still gets the old
		# behaviour rather than nothing.
		portal_paths = find_portal_paths(from_space, to_space)
	if portal_paths.is_empty():
		return result

	var best: Dictionary = {}
	var best_unwalkable := -1
	for portal_path in portal_paths:
		var legs: Array = []
		var leg_space := from_space
		var leg_from := from_position
		for portal in portal_path:
			legs.append(_build_leg(leg_space, leg_from, portal.source_position, portal))
			leg_space = portal.destination_space_form_id
			leg_from = portal.destination_position
		legs.append(_build_leg(leg_space, leg_from, to_position, null))

		var total := 0.0
		var unwalkable := 0
		for leg in legs:
			total += float(leg["length"])
			if not bool(leg["has_navmesh"]):
				unwalkable += 1
		var attempt := {
			"found": true,
			"legs": legs,
			"total_length": total,
			"door_count": portal_path.size(),
			"walkable": unwalkable == 0,
			"candidates_tried": portal_paths.size(),
			"from_component": from_component,
			"to_component": to_component,
		}
		if unwalkable == 0:
			return attempt
		if best_unwalkable < 0 or unwalkable < best_unwalkable:
			best_unwalkable = unwalkable
			best = attempt
	return best if not best.is_empty() else result

func _build_leg(space_form_id: int, from_position: Vector3, to_position: Vector3, exit_portal) -> Dictionary:
	var leg := {
		"space_form_id": space_form_id,
		"from": from_position,
		"to": to_position,
		"exit_portal": exit_portal,
		"has_navmesh": false,
		"waypoints": PackedVector3Array([from_position, to_position]),
		"length": from_position.distance_to(to_position),
	}
	# A door's authored position is often a little off the navmesh (it sits in
	# the doorway, not on the walkable surface), so this needs a wider radius
	# than actor grounding does.
	var leg_route: Dictionary = navmesh.find_route(space_form_id, from_position, to_position, ground_snap_radius * 4.0, use_coarse_index)
	if bool(leg_route.get("found", false)):
		leg["has_navmesh"] = true
		leg["waypoints"] = leg_route.get("waypoints", leg["waypoints"])
		leg["length"] = float(leg_route.get("length", leg["length"]))
	return leg

## The doors (NpcPortal, in order) from `from_position` in `from_space` to
## `to_position` in `to_space`: one sequence from the walkable-region door
## graph, whose legs are walkable by construction (a region is connected
## navmesh, and only doors join regions); the space-level search when an end
## is off navmesh. Empty when the two are already in one region, or no
## sequence exists (`found` tells which). Only the doors, no walking routes:
## a follower walks each leg's route when it starts that leg. Doors in
## `blocked_doors` (DoorReference -> true, from `blocked_doors_for`) are not
## used.
func find_door_sequence(from_space: int, from_position: Vector3, to_space: int, to_position: Vector3, blocked_doors: Dictionary = {}) -> Dictionary:
	var from_component := get_component_at(from_space, from_position, ground_snap_radius * 4.0)
	var to_component := get_component_at(to_space, to_position, ground_snap_radius * 4.0)
	var paths: Array = []
	if from_component >= 0 and to_component >= 0:
		paths = find_component_paths(from_component, to_component, 8, 1, blocked_doors)
	if paths.is_empty():
		paths = find_portal_paths(from_space, to_space, 8, 1, blocked_doors)
	if paths.is_empty():
		return {"found": false, "portals": []}
	return {"found": true, "portals": paths[0]}

## Whether `actor` may route through `door`: it is not locked, or the actor
## carries its key. Ownership (REFR XOWN / XRNK) is not read yet, so an owner
## without the key is not let through; lockpicking is not considered
## (Plans/Navigation/door_obstacle_cut.md, "Door passability").
func can_pass_door(actor: ActorReference, door: DoorReference) -> bool:
	if not door.is_locked:
		return true
	return door.lock_key_form_id != 0 and EsmBase.carries(actor, door.lock_key_form_id)

## The load doors `actor` may not route through, as find_door_sequence's
## `blocked_doors`. Built on the main thread: it reads the actor's inventory.
func blocked_doors_for(actor: ActorReference) -> Dictionary:
	var blocked := {}
	for door in lockable_doors:
		if not can_pass_door(actor, door):
			blocked[door] = true
	return blocked

## Debug: one line about the actors in the player's space, within `radius`
## metres of the player (0: the whole space): how many there are in the
## simulation, how many have a node (an NpcController), how many of those have
## their visual built, how many take their traits from a template (which
## render invisible until template appearance is read), and how many are
## still LOW_LEVEL.
func debug_report(radius: float) -> String:
	var player := ScriptServer.player_reference
	if player == null:
		return "no player"
	var near := 0
	var with_node := 0
	var visual_built := 0
	var templated := 0
	var low_level := 0
	for actor: ActorReference in get_actors_in_space(player.current_space_form_id):
		if radius > 0.0 and actor.position.distance_to(player.position) > radius:
			continue
		near += 1
		if actor.simulation_mode == ActorReference.SimulationMode.LOW_LEVEL:
			low_level += 1
		var base := actor.base as ActorBase
		if base != null and (base.template_flags & ActorBase.TEMPLATE_USE_TRAITS) != 0 and base.template_form_id != 0:
			templated += 1
		var controller := EsmNode.node_for(actor) as NpcController
		if controller == null:
			continue
		with_node += 1
		if controller.actor != null and controller.actor.is_visual_built():
			visual_built += 1
	var area := "within %.0f m" % radius if radius > 0.0 else "in this space"
	return "%s: %d actors; %d with a node, %d of those with their visual built; %d templated; %d LOW_LEVEL; simulation thread queue %d; routes not found: off screen %d, on screen %d" % [area, near, with_node, visual_built, templated, low_level, worker.get_pending_count(), low_level_travel.routes_not_found, NpcController.routes_not_found]

## find_door_sequence on this server's own thread (`worker`); the result
## arrives on [signal door_sequence_ready], with no portals when none was
## found.
func request_door_sequence(from_space: int, from_position: Vector3, to_space: int, to_position: Vector3, blocked_doors: Dictionary = {}) -> int:
	var request_id := _next_request_id
	_next_request_id += 1
	if navmesh == null:
		door_sequence_ready.emit.call_deferred(request_id, [])
		return request_id
	worker.post(_run_door_sequence_task.bind(request_id, from_space, from_position, to_space, to_position, blocked_doors))
	return request_id

func _run_door_sequence_task(request_id: int, from_space: int, from_position: Vector3, to_space: int, to_position: Vector3, blocked_doors: Dictionary) -> void:
	if _take_cancelled(request_id):
		return
	var result := find_door_sequence(from_space, from_position, to_space, to_position, blocked_doors)
	_finish_door_sequence.call_deferred(request_id, result["portals"])

## Main thread: a cancel that came after the job ran is forgotten, and a
## cancelled result is not delivered.
func _finish_door_sequence(request_id: int, portals: Array) -> void:
	if _take_cancelled(request_id):
		return
	door_sequence_ready.emit(request_id, portals)

## Async cross-space route, computed on this server's own thread (`worker`).
## Result arrives on [signal cross_space_route_ready].
func request_cross_space_route(from_space: int, from_position: Vector3, to_space: int, to_position: Vector3) -> int:
	var request_id := _next_request_id
	_next_request_id += 1
	if navmesh == null:
		cross_space_route_ready.emit.call_deferred(request_id, {"found": false})
		return request_id
	worker.post(_run_cross_space_task.bind(request_id, from_space, from_position, to_space, to_position))
	return request_id

func _run_cross_space_task(request_id: int, from_space: int, from_position: Vector3, to_space: int, to_position: Vector3) -> void:
	var result := route_across_spaces(from_space, from_position, to_space, to_position)
	_finish_cross_space_route.call_deferred(request_id, result)

func _finish_cross_space_route(request_id: int, result: Dictionary) -> void:
	cross_space_route_ready.emit(request_id, result)

func _is_tracked(reference: ActorReference) -> bool:
	return reference != null and actors_by_instance_id.get(reference.instance_id) == reference

func get_grounding_summary() -> Dictionary:
	var on_mesh := 0
	var near_mesh := 0
	var far_mesh := 0
	for grounding in grounding_by_instance_id.values():
		var distance := float(grounding.get("distance", 0.0))
		if distance <= 0.25:
			on_mesh += 1
		elif distance <= 2.0:
			near_mesh += 1
		else:
			far_mesh += 1
	return {
		"actors": actors_by_instance_id.size(),
		"grounded": grounding_by_instance_id.size(),
		"ungrounded": actors_by_instance_id.size() - grounding_by_instance_id.size(),
		"on_mesh": on_mesh,
		"near_mesh": near_mesh,
		"far_mesh": far_mesh,
	}
