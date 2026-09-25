class_name NavNpcSimulationServer
extends Node

## Navmesh-backed alternate to [NpcSimulationServer].
##
## The original NSS indexes actors by their raw authored positions alone, so it
## has no way to answer whether a point is real standable ground -- the question
## that motivated this variant. This one loads the whole game's authored NAVM
## data through [NavmeshReader] and grounds every actor against it.
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

## Max distance an actor may be from the navmesh and still be considered
## groundable, in meters.
@export var ground_snap_radius := 8.0
## Toggles the authored-NVGD-bounds broad-phase. False forces every query to
## test every triangle in the space -- same answer, far slower.
@export var use_coarse_index := true
@export_range(1, 1024, 1) var records_per_frame := 32

var navmesh: NavmeshReader
var actors_by_instance_id: Dictionary = {}
var actors_by_space_form_id: Dictionary = {}
var actors_by_cell_form_id: Dictionary = {}
## instance_id -> {position, distance, navmesh_form_id, global_triangle}. Only
## actors that actually snapped appear here.
var grounding_by_instance_id: Dictionary = {}
var portals: Array = []
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
var _route_tasks: Dictionary = {}

func _ready() -> void:
	seed.call_deferred()

func _exit_tree() -> void:
	# Same hazard EsmServer documents: destroying a running Thread aborts the
	# process, so a session quitting mid-load must wait for the read rather than
	# crash after its tests have already passed.
	if _load_thread != null and _load_thread.is_started():
		_load_thread.wait_to_finish()
	_load_thread = null
	for task_id in _route_tasks.values():
		if not WorkerThreadPool.is_task_completed(task_id):
			WorkerThreadPool.wait_for_task_completion(task_id)
	_route_tasks.clear()

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
	grounding_by_instance_id.clear()
	portals.clear()
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
			if door != null and door.has_teleport_destination and door.teleport_destination_cell_form_id != 0:
				var portal = NpcPortalScript.new()
				portal.source_reference = door
				portal.source_space_form_id = esm_server.get_space_form_id_for_cell(door.current_cell_form_id)
				portal.source_position = door.position
				portal.destination_space_form_id = esm_server.get_space_form_id_for_cell(door.teleport_destination_cell_form_id)
				portal.destination_position = door.teleport_position
				portals.append(portal)
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
	_add_to_index(actors_by_space_form_id, actor.current_space_form_id, actor)
	_add_to_index(actors_by_cell_form_id, actor.current_cell_form_id, actor)
	var grounding := ground(actor)
	if not grounding.is_empty():
		grounding_by_instance_id[actor.instance_id] = grounding

func _add_to_index(index: Dictionary, key: int, actor: ActorReference) -> void:
	if not index.has(key):
		index[key] = {}
	index[key][actor.instance_id] = actor

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
func request_route(space_form_id: int, from: Vector3, to: Vector3) -> int:
	var request_id := _next_request_id
	_next_request_id += 1
	if navmesh == null:
		route_ready.emit.call_deferred(request_id, {"found": false})
		return request_id
	var task_id := WorkerThreadPool.add_task(_run_route_task.bind(request_id, space_form_id, from, to))
	_route_tasks[request_id] = task_id
	return request_id

func _run_route_task(request_id: int, space_form_id: int, from: Vector3, to: Vector3) -> void:
	var result := route(space_form_id, from, to)
	_finish_route.call_deferred(request_id, result)

func _finish_route(request_id: int, result: Dictionary) -> void:
	var task_id: int = _route_tasks.get(request_id, -1)
	if task_id != -1:
		WorkerThreadPool.wait_for_task_completion(task_id)
		_route_tasks.erase(request_id)
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
func find_portal_paths(from_space: int, to_space: int, max_doors := 8, max_paths := 4) -> Array:
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
func find_component_paths(from_component: int, to_component: int, max_doors := 8, max_paths := 4) -> Array:
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

## Async cross-space route. Result arrives on [signal cross_space_route_ready].
func request_cross_space_route(from_space: int, from_position: Vector3, to_space: int, to_position: Vector3) -> int:
	var request_id := _next_request_id
	_next_request_id += 1
	if navmesh == null:
		cross_space_route_ready.emit.call_deferred(request_id, {"found": false})
		return request_id
	var task_id := WorkerThreadPool.add_task(_run_cross_space_task.bind(request_id, from_space, from_position, to_space, to_position))
	_route_tasks[request_id] = task_id
	return request_id

func _run_cross_space_task(request_id: int, from_space: int, from_position: Vector3, to_space: int, to_position: Vector3) -> void:
	var result := route_across_spaces(from_space, from_position, to_space, to_position)
	_finish_cross_space_route.call_deferred(request_id, result)

func _finish_cross_space_route(request_id: int, result: Dictionary) -> void:
	var task_id: int = _route_tasks.get(request_id, -1)
	if task_id != -1:
		WorkerThreadPool.wait_for_task_completion(task_id)
		_route_tasks.erase(request_id)
	cross_space_route_ready.emit(request_id, result)

## A lease changes only mutual-execution ownership, exactly as in the original
## NSS. The one addition is that an actor with no ground under it cannot be
## leased for physical simulation -- there is nowhere valid to put it.
func checkout(reference: ActorReference) -> bool:
	if not _is_tracked(reference) or reference.simulation_mode != ActorReference.SimulationMode.LOW_LEVEL:
		return false
	if not is_grounded(reference):
		return false
	reference.simulation_mode = ActorReference.SimulationMode.PHYSICAL_LEASED
	return true

func checkin(reference: ActorReference) -> bool:
	if not _is_tracked(reference) or reference.simulation_mode != ActorReference.SimulationMode.PHYSICAL_LEASED:
		return false
	reference.simulation_mode = ActorReference.SimulationMode.LOW_LEVEL
	return true

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
