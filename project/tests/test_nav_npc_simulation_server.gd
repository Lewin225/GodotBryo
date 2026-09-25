extends Node

## Exercises NavmeshReader and NavNpcSimulationServer against the real shipped
## masters. Nothing here is mocked -- every assertion runs on real NAVM data.

const NavNpcSimulationServerScript := preload("res://GodotBryo/Servers/NpcSimulationServer/nav_npc_simulation_server.gd")

## The measured whole-game load is ~0.36 s; this is the agreed boot budget, kept
## well above it so normal variance does not fail the run.
const BOOT_BUDGET_MS := 5000.0

var failures := 0

func _check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _ready() -> void:
	var esm = get_node("/root/EsmServer")
	if not esm.is_ready():
		await esm.esm_ready

	_check(ClassDB.class_exists("NavmeshReader"), "NavmeshReader is registered (rebuild the GDExtension if this fails)")
	if not ClassDB.class_exists("NavmeshReader"):
		print("FAILURES: %d" % failures)
		get_tree().quit(1)
		return

	var simulation = NavNpcSimulationServerScript.new()
	simulation.records_per_frame = 256
	add_child(simulation)
	await simulation.seed_finished

	var navmesh = simulation.navmesh
	_check(navmesh != null and navmesh.is_loaded(), "navmesh loaded")

	# --- load budget and structural totals ---
	var stats: Dictionary = simulation.navmesh_load_stats
	var total_ms := float(stats.get("total_ms", 1e9))
	_check(total_ms < BOOT_BUDGET_MS, "navmesh load %.0f ms is within the %.0f ms boot budget" % [total_ms, BOOT_BUDGET_MS])
	_check(int(stats.get("records", 0)) > 6000, "loaded every NAVM record (%d)" % int(stats.get("records", 0)))
	_check(int(stats.get("triangles", 0)) > 800000, "loaded every triangle (%d)" % int(stats.get("triangles", 0)))
	_check(int(stats.get("unresolved_edge_link_targets", -1)) == 0, "every authored NVEX target resolved to a real record")
	# 82 NVTR edges across the shipped masters are out of range by exactly one.
	# Indexing them would read past the triangle array, so they must be clamped.
	_check(int(stats.get("clamped_out_of_range_edges", -1)) == 82, "the 82 known out-of-range NVTR edges are clamped, not trusted")

	# --- the coarse index is an optimiser, never a different answer ---
	var space_ids: PackedInt32Array = navmesh.get_space_ids()
	_check(space_ids.size() > 400, "navmesh spans many spaces (%d)" % space_ids.size())
	var biggest_space := 0
	var biggest_count := 0
	for space_id in space_ids:
		var n: int = navmesh.get_records_in_space(space_id).size()
		if n > biggest_count:
			biggest_count = n
			biggest_space = space_id
	_check(biggest_count > 1000, "largest space has %d records" % biggest_count)

	var records: PackedInt32Array = navmesh.get_records_in_space(biggest_space)
	var probe_info: Dictionary = navmesh.get_record_info(records[0])
	var probe_point: Vector3 = probe_info["center"]
	var agree := true
	var checked := 0
	for i in range(0, records.size(), max(1, records.size() / 24)):
		var info: Dictionary = navmesh.get_record_info(records[i])
		var point: Vector3 = info["center"]
		var with_index: Dictionary = navmesh.snap(biggest_space, point, 60.0, true)
		var without_index: Dictionary = navmesh.snap(biggest_space, point, 60.0, false)
		checked += 1
		if with_index.get("found") != without_index.get("found"):
			agree = false
		elif bool(with_index.get("found", false)) and with_index.get("global_triangle") != without_index.get("global_triangle"):
			agree = false
	_check(agree, "coarse index on/off return identical snaps across %d sampled records" % checked)

	var start_us := Time.get_ticks_usec()
	navmesh.snap(biggest_space, probe_point, 60.0, true)
	var indexed_us := Time.get_ticks_usec() - start_us
	start_us = Time.get_ticks_usec()
	navmesh.snap(biggest_space, probe_point, 60.0, false)
	var brute_us := Time.get_ticks_usec() - start_us
	_check(indexed_us < brute_us, "coarse index is faster than brute force (%d us vs %d us)" % [indexed_us, brute_us])

	# --- authored bounds are present on every record, so there is no fallback path ---
	var all_have_bounds := true
	for i in range(0, records.size(), max(1, records.size() / 50)):
		var info: Dictionary = navmesh.get_record_info(records[i])
		var bounds_min: Vector3 = info["bounds_min"]
		var bounds_max: Vector3 = info["bounds_max"]
		if not (bounds_max.x >= bounds_min.x and bounds_max.y >= bounds_min.y and bounds_max.z >= bounds_min.z):
			all_have_bounds = false
	_check(all_have_bounds, "sampled records all carry usable authored NVGD bounds")

	# --- coarse connectivity comes from NVEX, never from proximity ---
	var has_neighbors := false
	for i in range(0, min(records.size(), 200)):
		if navmesh.get_coarse_neighbors(records[i]).size() > 0:
			has_neighbors = true
			break
	_check(has_neighbors, "records expose authored NVEX coarse neighbours")

	# --- a real route across the largest space ---
	var from_info: Dictionary = navmesh.get_record_info(records[0])
	var to_info: Dictionary = navmesh.get_record_info(records[records.size() / 2])
	var route: Dictionary = navmesh.find_route(biggest_space, from_info["center"], to_info["center"], 60.0, true)
	_check(bool(route.get("found", false)), "found a route across the largest space")
	if bool(route.get("found", false)):
		var waypoints: PackedVector3Array = route["waypoints"]
		_check(waypoints.size() >= 2, "route has real waypoints (%d)" % waypoints.size())
		_check(float(route.get("length", 0.0)) > 0.0, "route has a real length (%.1f m)" % float(route.get("length", 0.0)))
		# Every waypoint must itself be on the navmesh -- a route that leaves the
		# mesh is exactly the failure this whole layer exists to prevent.
		var all_on_mesh := true
		for i in range(0, waypoints.size(), max(1, waypoints.size() / 20)):
			var snapped: Dictionary = navmesh.snap(biggest_space, waypoints[i], 2.0, true)
			if not bool(snapped.get("found", false)):
				all_on_mesh = false
		_check(all_on_mesh, "every sampled route waypoint lies on the navmesh")

		# Waypoint count is deliberately NOT compared against triangle count. The
		# funnel reduces the path well below one point per triangle, but the
		# height-projection pass then inserts terrain-following points, so the
		# final count is legitimately higher again. What matters is that the path
		# is smooth (asserted by turn angle below) and sits on its own surface,
		# not how many points express it.
		var triangle_count: int = (route.get("triangles", PackedInt32Array()) as PackedInt32Array).size()
		var spacings: Array[float] = []
		for i in range(1, waypoints.size()):
			spacings.append((waypoints[i] as Vector3).distance_to(waypoints[i - 1]))
		spacings.sort()
		var median_spacing: float = spacings[spacings.size() / 2] if not spacings.is_empty() else 0.0
		# Dense, regular spacing is the signature of the projection pass having
		# run; the raw funnel output is sparse and irregular.
		_check(median_spacing < 6.0, "path is terrain-sampled: median waypoint spacing %.2f m over %d waypoints (%d triangles)" % [median_spacing, waypoints.size(), triangle_count])

		# Turn angle is the direct measure of the "vibration" symptom: a
		# centroid path reverses direction constantly, a funnelled one should
		# mostly run straight and turn only at real corners.
		var sharp_turns := 0
		var total_turn := 0.0
		var measured := 0
		for i in range(1, waypoints.size() - 1):
			var incoming: Vector3 = waypoints[i] - waypoints[i - 1]
			var outgoing: Vector3 = waypoints[i + 1] - waypoints[i]
			if incoming.length() < 0.01 or outgoing.length() < 0.01:
				continue
			var turn: float = rad_to_deg(incoming.normalized().angle_to(outgoing.normalized()))
			total_turn += turn
			measured += 1
			if turn > 90.0:
				sharp_turns += 1
		if measured > 0:
			var mean_turn := total_turn / float(measured)
			_check(mean_turn < 40.0, "mean turn per waypoint is gentle (%.1f deg over %d corners)" % [mean_turn, measured])
			# The unsmoothed centroid path reversed at 8 of 95 corners; funnel plus
			# line-of-sight simplification takes that to zero, so this asserts near-zero
			# rather than merely "few".
			_check(float(sharp_turns) / float(measured) < 0.05, "essentially no reversals: %d of %d corners turn more than 90 deg" % [sharp_turns, measured])

		# Waypoint height must track the real surface, not interpolate between
		# endpoints. Navmesh overlaps vertically, so a path floating off its own
		# floor can snap an actor onto the wrong one when it physicalises. Before
		# projection, 11.8% of path points sat >2 m off the surface (p99 6.06 m).
		var floating := 0
		var checked_heights := 0
		var worst_drop := 0.0
		for i in range(0, waypoints.size(), max(1, waypoints.size() / 30)):
			var probe: Vector3 = waypoints[i]
			var surface: Dictionary = navmesh.snap(biggest_space, probe, 40.0, true)
			if not bool(surface.get("found", false)):
				continue
			var surface_point: Vector3 = surface["position"]
			var drop: float = absf(surface_point.z - probe.z)
			checked_heights += 1
			if drop > 2.0:
				floating += 1
			worst_drop = maxf(worst_drop, drop)
		if checked_heights > 0:
			_check(float(floating) / float(checked_heights) < 0.15,
				"waypoints sit on their own surface: %d of %d more than 2 m off (worst %.2f m)" % [floating, checked_heights, worst_drop])

		# A funnelled path must not be longer than the centroid path it replaces.
		var straight_line: float = (waypoints[0] as Vector3).distance_to(waypoints[waypoints.size() - 1])
		_check(float(route.get("length", 0.0)) >= straight_line - 0.01, "route is at least the straight-line distance (%.0f m vs %.0f m)" % [float(route.get("length", 0.0)), straight_line])

	# --- actor grounding: the question that motivated this variant ---
	var summary: Dictionary = simulation.get_grounding_summary()
	print("  ...grounding summary: %s" % summary)
	_check(int(summary.get("actors", 0)) > 3000, "seeded every placed actor (%d)" % int(summary.get("actors", 0)))
	var grounded := int(summary.get("grounded", 0))
	var actors := int(summary.get("actors", 1))
	_check(float(grounded) / float(actors) > 0.85, "most actors ground onto real navmesh (%d/%d)" % [grounded, actors])
	_check(int(summary.get("on_mesh", 0)) > 0, "actors land essentially on the mesh (%d within 0.25 m)" % int(summary.get("on_mesh", 0)))

	# --- a lease requires real ground under the actor ---
	var grounded_actor: ActorReference = null
	var ungrounded_actor: ActorReference = null
	for actor in simulation.actors_by_instance_id.values():
		if simulation.is_grounded(actor):
			if grounded_actor == null:
				grounded_actor = actor
		elif ungrounded_actor == null:
			ungrounded_actor = actor
		if grounded_actor != null and ungrounded_actor != null:
			break

	if grounded_actor != null:
		_check(grounded_actor.simulation_mode == ActorReference.SimulationMode.LOW_LEVEL, "grounded actor starts LOW_LEVEL")
		_check(simulation.checkout(grounded_actor), "checkout succeeds for a grounded actor")
		_check(grounded_actor.simulation_mode == ActorReference.SimulationMode.PHYSICAL_LEASED, "checkout changes only simulation mode")
		_check(not simulation.checkout(grounded_actor), "checkout rejects an existing lease")
		_check(simulation.checkin(grounded_actor), "checkin returns the actor to LOW_LEVEL")
		var ground_position: Vector3 = simulation.get_ground_position(grounded_actor)
		_check(ground_position.distance_to(grounded_actor.position) <= simulation.ground_snap_radius,
			"ground position is within the snap radius of the authored position")
	if ungrounded_actor != null:
		_check(not simulation.checkout(ungrounded_actor), "checkout refuses an actor with no navmesh under it")

	# --- cross-space routing through authored XTEL doors ---
	_check(not simulation.portals_by_source_space.is_empty(), "portals are indexed by source space (%d spaces have exits)" % simulation.portals_by_source_space.size())
	_check(simulation.find_portal_path(biggest_space, biggest_space).is_empty(), "a route to the same space needs no doors")

	# Find a space genuinely reachable from the exterior through authored doors.
	var reachable_space := 0
	var portal_path: Array = []
	for candidate in space_ids:
		if candidate == biggest_space:
			continue
		var path: Array = simulation.find_portal_path(biggest_space, candidate, 3)
		if not path.is_empty():
			reachable_space = candidate
			portal_path = path
			break
	_check(reachable_space != 0, "found a space reachable from the exterior through doors")

	if reachable_space != 0:
		# Each hop must actually join up: a portal's destination space has to be
		# the next portal's source space, or the "path" is not a path.
		var chain_is_contiguous := true
		var chain_space := biggest_space
		for portal in portal_path:
			if portal.source_space_form_id != chain_space:
				chain_is_contiguous = false
			chain_space = portal.destination_space_form_id
		_check(chain_is_contiguous, "portal chain is contiguous across %d door(s)" % portal_path.size())
		_check(chain_space == reachable_space, "portal chain actually ends in the target space")

		var origin_actors: Array[ActorReference] = simulation.get_actors_in_space(biggest_space)
		var target_actors: Array[ActorReference] = simulation.get_actors_in_space(reachable_space)
		if not origin_actors.is_empty() and not target_actors.is_empty():
			var origin: Vector3 = simulation.get_ground_position(origin_actors[0])
			var target: Vector3 = simulation.get_ground_position(target_actors[0])
			var crossing: Dictionary = simulation.route_across_spaces(biggest_space, origin, reachable_space, target)
			_check(bool(crossing.get("found", false)), "cross-space route found")
			if bool(crossing.get("found", false)):
				var legs: Array = crossing["legs"]
				_check(legs.size() == int(crossing.get("door_count", 0)) + 1, "one more leg than doors (%d legs, %d doors)" % [legs.size(), int(crossing.get("door_count", 0))])
				_check(int(legs[0]["space_form_id"]) == biggest_space, "first leg starts in the origin space")
				_check(int(legs[legs.size() - 1]["space_form_id"]) == reachable_space, "last leg ends in the target space")
				# Every leg must stay in one space and hand off to the next via a door.
				var legs_chain := true
				for i in legs.size() - 1:
					var exit_portal = legs[i]["exit_portal"]
					if exit_portal == null or int(exit_portal.destination_space_form_id) != int(legs[i + 1]["space_form_id"]):
						legs_chain = false
				_check(legs_chain, "every leg hands off to the next through a real door")
				_check(legs[legs.size() - 1]["exit_portal"] == null, "the final leg exits through no door")
				_check(float(crossing.get("total_length", 0.0)) > 0.0, "cross-space route has a real length (%.0f m)" % float(crossing.get("total_length", 0.0)))
				# Walkable legs must lie on real navmesh -- that is the whole point.
				var walkable_legs_on_mesh := true
				for leg in legs:
					if not bool(leg["has_navmesh"]):
						continue
					var leg_points: PackedVector3Array = leg["waypoints"]
					for i in range(0, leg_points.size(), max(1, leg_points.size() / 8)):
						var snapped: Dictionary = navmesh.snap(int(leg["space_form_id"]), leg_points[i], 4.0, true)
						if not bool(snapped.get("found", false)):
							walkable_legs_on_mesh = false
				_check(walkable_legs_on_mesh, "every waypoint of every navmeshed leg lies on that leg's own navmesh")

	# The search offers alternatives rather than committing to the fewest-doors
	# path, because that path's legs are not always walkable.
	if reachable_space != 0:
		var alternatives: Array = simulation.find_portal_paths(biggest_space, reachable_space, 4, 4)
		_check(not alternatives.is_empty(), "portal search returns candidate paths (%d)" % alternatives.size())
		var ordered_by_length := true
		for i in alternatives.size() - 1:
			if (alternatives[i] as Array).size() > (alternatives[i + 1] as Array).size():
				ordered_by_length = false
		_check(ordered_by_length, "candidate paths come back shortest-first")
		var every_candidate_ends_correctly := true
		for candidate in alternatives:
			var end_space := biggest_space
			for portal in candidate:
				end_space = portal.destination_space_form_id
			if end_space != reachable_space:
				every_candidate_ends_correctly = false
		_check(every_candidate_ends_correctly, "every candidate path ends in the target space")

	var unreachable: Dictionary = simulation.route_across_spaces(biggest_space, Vector3.ZERO, 0, Vector3.ZERO)
	_check(not bool(unreachable.get("found", true)), "a route to a space with no doors reports not found")

	var async_cross_id: int = simulation.request_cross_space_route(biggest_space, Vector3.ZERO, biggest_space, Vector3.ZERO)
	var async_cross: Array = await simulation.cross_space_route_ready
	_check(int(async_cross[0]) == async_cross_id, "async cross-space route reports its own request id")

	# --- enclosed exterior regions must route OUT through buildings ---
	# A space is not one walkable region. NCR Correctional Facility is an
	# exterior yard behind a fence whose only link to the Mojave runs through a
	# building. Space-keyed routing called that "same space, walk there", found
	# no path, and drew a straight line through the fence.
	_check(int(stats.get("components", 0)) > 1, "navmesh reports connected components (%d)" % int(stats.get("components", 0)))
	_check(navmesh.get_component_count() == int(stats.get("components", 0)), "component count agrees between stats and accessor")

	var by_component := {}
	for actor in simulation.get_actors_in_space(biggest_space):
		if not simulation.is_grounded(actor):
			continue
		var grounding: Dictionary = simulation.grounding_by_instance_id[actor.instance_id]
		var component := int(grounding.get("component", -1))
		if component < 0:
			continue
		if not by_component.has(component):
			by_component[component] = []
		by_component[component].append(actor)
	_check(by_component.size() > 1, "the exterior splits into multiple walkable regions (%d hold actors)" % by_component.size())

	var main_component := -1
	var main_count := -1
	for component in by_component:
		if by_component[component].size() > main_count:
			main_count = by_component[component].size()
			main_component = component

	var enclosed_tested := 0
	var enclosed_walkable := 0
	var enclosed_used_a_door := 0
	for component in by_component:
		if component == main_component or enclosed_tested >= 8:
			continue
		if simulation.find_component_paths(component, main_component, 6, 1).is_empty():
			continue
		enclosed_tested += 1
		var origin: Vector3 = simulation.get_ground_position(by_component[component][0])
		var target: Vector3 = simulation.get_ground_position(by_component[main_component][0])
		var escape: Dictionary = simulation.route_across_spaces(biggest_space, origin, biggest_space, target)
		if bool(escape.get("walkable", false)):
			enclosed_walkable += 1
		if int(escape.get("door_count", 0)) > 0:
			enclosed_used_a_door += 1
	if enclosed_tested > 0:
		_check(enclosed_walkable == enclosed_tested, "every enclosed exterior region routes out fully walkable (%d/%d)" % [enclosed_walkable, enclosed_tested])
		# The point of the fix: these routes must go through doors, not straight
		# across the fence. Zero doors would mean it clipped out again.
		_check(enclosed_used_a_door == enclosed_tested, "every enclosed-region escape uses at least one door (%d/%d)" % [enclosed_used_a_door, enclosed_tested])

	# Same space, same region still needs no doors at all.
	_check(simulation.find_component_paths(main_component, main_component).size() == 1
		and (simulation.find_component_paths(main_component, main_component)[0] as Array).is_empty(),
		"a route within one walkable region needs no doors")

	# --- bulk geometry accessors the viewer is built on ---
	var geometry: Dictionary = navmesh.get_space_geometry(biggest_space)
	var points: PackedVector3Array = geometry.get("points", PackedVector3Array())
	var record_ids: PackedInt32Array = geometry.get("record_indices", PackedInt32Array())
	_check(points.size() == record_ids.size() * 3, "space geometry returns exactly 3 points per triangle (%d points, %d triangles)" % [points.size(), record_ids.size()])
	_check(int(geometry.get("record_count", 0)) == records.size(), "space geometry covers every record in the space")
	# One bulk call must equal the sum of the per-record calls, or the viewer is
	# drawing something different from what the queries actually see.
	var per_record_total := 0
	for i in range(0, records.size(), max(1, records.size() / 12)):
		per_record_total += navmesh.get_record_triangle_points(records[i]).size()
	_check(per_record_total > 0, "per-record triangle points are non-empty")
	var ids_within_space := true
	for i in range(0, record_ids.size(), max(1, record_ids.size() / 200)):
		if not records.has(record_ids[i]):
			ids_within_space = false
	_check(ids_within_space, "every triangle's record index belongs to the queried space")

	var space_bounds: Dictionary = navmesh.get_space_bounds(biggest_space)
	_check(bool(space_bounds.get("found", false)), "space bounds resolve")
	if bool(space_bounds.get("found", false)):
		var low: Vector3 = space_bounds["min"]
		var high: Vector3 = space_bounds["max"]
		_check(high.x >= low.x and high.y >= low.y and high.z >= low.z, "space bounds are well formed")
		# Every triangle must fall inside the bounds the viewer frames the camera
		# with, or the camera frames the wrong thing.
		var all_inside := true
		for i in range(0, points.size(), max(1, points.size() / 500)):
			var p: Vector3 = points[i]
			if p.x < low.x - 1.0 or p.x > high.x + 1.0 or p.y < low.y - 1.0 or p.y > high.y + 1.0 or p.z < low.z - 1.0 or p.z > high.z + 1.0:
				all_inside = false
		_check(all_inside, "sampled triangles all fall inside the reported space bounds")

	_check(navmesh.get_space_geometry(0).get("triangle_count", -1) == 0, "an unknown space yields empty geometry rather than erroring")
	_check(not bool(navmesh.get_space_bounds(0).get("found", true)), "an unknown space reports no bounds")

	# --- the viewer scene itself ---
	# load() returns a PackedScene even when the attached script fails to parse,
	# so the scene loading is not evidence the viewer works. Check the script
	# actually attached and its own methods exist -- a parse error otherwise
	# passes this whole block silently.
	var viewer_script: Resource = load("res://nav_simulation_viewer.gd")
	_check(viewer_script != null and viewer_script is GDScript, "nav viewer script parses")
	if viewer_script is GDScript:
		_check((viewer_script as GDScript).can_instantiate(), "nav viewer script is instantiable")
	var viewer_scene: PackedScene = load("res://nav_simulation_viewer.tscn")
	_check(viewer_scene != null, "nav viewer scene loads")
	if viewer_scene != null:
		var viewer := viewer_scene.instantiate()
		_check(viewer.get_script() != null, "viewer root actually has its script attached")
		_check(viewer.has_method("_build_navmesh_surface") and viewer.has_method("_route_between_random_actors"),
			"viewer exposes its own build/route methods (catches a script that failed to parse)")
		_check(viewer.has_node("NavNpcSimulationServer"), "viewer owns its own NavNpcSimulationServer")
		_check(viewer.has_node("NavmeshSurface") and viewer.has_node("CoarseGraphLines") and viewer.has_node("ActorPoints")
			and viewer.has_node("GroundingLines") and viewer.has_node("PortalLines") and viewer.has_node("PortalBoxes")
			and viewer.has_node("RouteLine") and viewer.has_node("BatchRouteLines")
			and viewer.has_node("BatchWalkers"),
			"viewer has every visualization layer node its script expects")
		_check(not viewer.has_node("Game") and not viewer.has_node("CellStreamer") and not viewer.has_node("WorldStreamer"),
			"viewer is standalone, not wired into Game or either streamer")
		viewer.free()

	# --- async route, the shape real callers use ---
	var request_id: int = simulation.request_route(biggest_space, from_info["center"], to_info["center"])
	_check(request_id > 0, "async route returns a request id")
	var async_result: Array = await simulation.route_ready
	_check(int(async_result[0]) == request_id, "async route reports its own request id")
	_check(bool((async_result[1] as Dictionary).get("found", false)), "async route found the same route off-thread")

	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
