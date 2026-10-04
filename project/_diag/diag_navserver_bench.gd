extends Node3D

## Benchmark: WastelandNV's whole NAVM in Godot's NavigationServer3D against
## NavmeshReader (NpcSimulationServer's router). One map; one region per NAVM
## record (vertices welded by position), built on worker threads; records
## joined by NavmeshReader's derived cross-record pairs as two-way links
## between triangle centres (argument `nolinks` leaves them out). Then 100 seeded random routes through both, then 100 avoidance agents
## following their Godot paths. The map's edge connection margin is the first
## user argument after `--` (metres; Godot's default 0.25); a second argument
## `noedges` turns the map's edge connections off.

var links: Array[RID] = []

const WASTELAND_EDITOR_ID := "WastelandNV"
const ROUTES := 100
const AGENT_FRAMES := 600
const SEED := 1234

var reader: Object
var map: RID
var space_form_id := 0
var regions: Array[RID] = []

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	space_form_id = EsmServer.find_form_id_by_editor_id(WASTELAND_EDITOR_ID)
	reader = ClassDB.instantiate("NavmeshReader")
	var config := preload("res://game_data_config.gd").resolve()
	var started := Time.get_ticks_msec()
	reader.load_plugins(PackedStringArray([String(config.get("data_dir", "")) + "FalloutNV.esm"]))
	print("NavmeshReader load (FalloutNV.esm): %d ms" % (Time.get_ticks_msec() - started))
	var records: PackedInt32Array = reader.get_records_in_space(space_form_id)
	print("WastelandNV: %d NAVM records" % records.size())
	await _build_map(records)
	_probe_links()
	_compare_within_records(records)
	var pairs := _route_pairs(records)
	_compare_routes(pairs, 4096)
	_compare_routes(pairs, 0)
	await _run_agents(pairs)
	NavigationServer3D.free_rid(map)
	get_tree().quit()

func _build_map(records: PackedInt32Array) -> void:
	var memory_before := Performance.get_monitor(Performance.MEMORY_STATIC)
	map = NavigationServer3D.map_create()
	var margin := 0.25
	if not OS.get_cmdline_user_args().is_empty():
		margin = float(OS.get_cmdline_user_args()[0])
	NavigationServer3D.map_set_edge_connection_margin(map, margin)
	var use_edge_connections := not OS.get_cmdline_user_args().has("noedges")
	NavigationServer3D.map_set_use_edge_connections(map, use_edge_connections)
	print("edge connection margin %.2f m, edge connections %s" % [margin, "on" if use_edge_connections else "off"])
	NavigationServer3D.map_set_cell_size(map, 0.25)
	NavigationServer3D.map_set_cell_height(map, 0.25)
	NavigationServer3D.map_set_active(map, true)
	var started := Time.get_ticks_msec()
	var meshes: Array[NavigationMesh] = []
	meshes.resize(records.size())
	var task := WorkerThreadPool.add_group_task(func(i: int) -> void: meshes[i] = _navigation_mesh(int(records[i])), records.size())
	WorkerThreadPool.wait_for_group_task_completion(task)
	var built_ms := Time.get_ticks_msec() - started
	var triangles := 0
	for mesh in meshes:
		triangles += mesh.get_polygon_count()
		var region := NavigationServer3D.region_create()
		regions.append(region)
		NavigationServer3D.region_set_map(region, map)
		NavigationServer3D.region_set_navigation_mesh(region, mesh)
	var regions_ms := Time.get_ticks_msec() - started
	if not OS.get_cmdline_user_args().has("nolinks"):
		_add_cross_links()
	var links_ms := Time.get_ticks_msec() - started
	var iteration := NavigationServer3D.map_get_iteration_id(map)
	while NavigationServer3D.map_get_iteration_id(map) == iteration:
		await get_tree().physics_frame
	var first_sync_ms := Time.get_ticks_msec() - started
	var waited := 0.0
	while waited < 120.0:
		_probe_record(int(records[0]))
		print("    at %.1f s: map iteration %d, map regions %d, record's region closest point %.2f m" % [
			(Time.get_ticks_msec() - started) / 1000.0, NavigationServer3D.map_get_iteration_id(map),
			NavigationServer3D.map_get_regions(map).size(), _region_probe(regions[0], int(records[0]))])
		if NavigationServer3D.map_get_closest_point(map, _centre(int(records[0]), 0)).distance_to(_centre(int(records[0]), 0)) < 0.5:
			break
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
	meshes.clear()
	var memory_after := Performance.get_monitor(Performance.MEMORY_STATIC)
	print("Godot map: %d regions, %d polygons, %d links; meshes built %d ms, regions set %d ms, links set %d ms, first iteration %d ms; static memory +%.1f MB" % [
		records.size(), triangles, links.size(), built_ms, regions_ms, links_ms, first_sync_ms, (memory_after - memory_before) / 1048576.0])
	print("  navigation monitors: polygons %d, edges %d, edges merged %d, edges connected %d, free edges %d" % [
		Performance.get_monitor(Performance.NAVIGATION_3D_POLYGON_COUNT), Performance.get_monitor(Performance.NAVIGATION_3D_EDGE_COUNT),
		Performance.get_monitor(Performance.NAVIGATION_3D_EDGE_MERGE_COUNT), Performance.get_monitor(Performance.NAVIGATION_3D_EDGE_CONNECTION_COUNT),
		Performance.get_monitor(Performance.NAVIGATION_3D_EDGE_FREE_COUNT)])

## Gamebryo Z-up (NavmeshReader, EsmReference) to Godot Y-up, as EsmNode's
## placement basis: (x, y, z) -> (x, z, -y).
static func to_godot(point: Vector3) -> Vector3:
	return Vector3(point.x, point.z, -point.y)

func _centre(record_index: int, triangle: int) -> Vector3:
	var points: PackedVector3Array = reader.get_record_triangle_points(record_index)
	return to_godot((points[triangle * 3] + points[triangle * 3 + 1] + points[triangle * 3 + 2]) / 3.0)

func _region_probe(region: RID, record_index: int) -> float:
	var centre := _centre(record_index, 0)
	return NavigationServer3D.region_get_closest_point(region, centre).distance_to(centre)

## One two-way link per derived cross-record pair.
func _add_cross_links() -> void:
	var pairs: PackedVector3Array = reader.get_space_cross_links(space_form_id)
	for i in range(0, pairs.size(), 2):
		var link := NavigationServer3D.link_create()
		NavigationServer3D.link_set_map(link, map)
		NavigationServer3D.link_set_bidirectional(link, true)
		NavigationServer3D.link_set_start_position(link, to_godot(pairs[i]))
		NavigationServer3D.link_set_end_position(link, to_godot(pairs[i + 1]))
		links.append(link)

## Routes between the first and last triangles of 200 records, each record
## alone: Godot relies on merged vertices inside a region, NavmeshReader on
## NVTR adjacency.
func _compare_within_records(records: PackedInt32Array) -> void:
	var godot_reached := 0
	var ours_found := 0
	var ours_only := 0
	var checked := 0
	for i in range(0, records.size(), maxi(1, records.size() / 200)):
		var record := int(records[i])
		var points: PackedVector3Array = reader.get_record_triangle_points(record)
		if points.size() < 6:
			continue
		var from := _centre(record, 0)
		var to := _centre(record, points.size() / 3 - 1)
		var path := NavigationServer3D.map_get_path(map, from, to, true)
		var godot_ok := path.size() > 0 and path[path.size() - 1].distance_to(to) < 0.5
		var route: Dictionary = reader.find_route(space_form_id, _to_gamebryo(from), _to_gamebryo(to), 8.0, true)
		var ours_ok := bool(route.get("found", false))
		checked += 1
		if godot_ok:
			godot_reached += 1
		if ours_ok:
			ours_found += 1
		if ours_ok and not godot_ok:
			ours_only += 1
	print("  within one record (%d records): Godot reached %d, ours found %d, ours only %d" % [checked, godot_reached, ours_found, ours_only])

static func _to_gamebryo(point: Vector3) -> Vector3:
	return Vector3(point.x, -point.z, point.y)

## Paths across the first 20 links (start to end), and where one route
## between two far triangles ends.
func _probe_links() -> void:
	var crossed := 0
	for i in mini(20, links.size()):
		var start := NavigationServer3D.link_get_start_position(links[i])
		var end := NavigationServer3D.link_get_end_position(links[i])
		var path := NavigationServer3D.map_get_path(map, start, end, true)
		if path.size() > 0 and path[path.size() - 1].distance_to(end) < 0.5:
			crossed += 1
		if i < 3:
			print("  link %d: %s -> %s (%.1f m apart), path %d points, ends %.2f m from the end" % [
				i, start, end, start.distance_to(end), path.size(),
				path[path.size() - 1].distance_to(end) if path.size() > 0 else -1.0])
	print("  links crossed: %d of %d" % [crossed, mini(20, links.size())])

## A path between the first and last triangles of one record, and how far the
## map's closest point is from each end.
func _probe_record(record_index: int) -> void:
	var points: PackedVector3Array = reader.get_record_triangle_points(record_index)
	var from := to_godot((points[0] + points[1] + points[2]) / 3.0)
	var last := points.size() - 3
	var to := to_godot((points[last] + points[last + 1] + points[last + 2]) / 3.0)
	var path := NavigationServer3D.map_get_path(map, from, to, true)
	print("  probe record %d: closest point %.2f m / %.2f m from the ends, path %d points" % [
		record_index, NavigationServer3D.map_get_closest_point(map, from).distance_to(from),
		NavigationServer3D.map_get_closest_point(map, to).distance_to(to), path.size()])

## One record's triangles as a NavigationMesh in Godot axes, vertices welded by
## position, each triangle wound clockwise seen from above (the winding
## Godot's own baker produces).
func _navigation_mesh(record_index: int) -> NavigationMesh:
	var points: PackedVector3Array = reader.get_record_triangle_points(record_index)
	var mesh := NavigationMesh.new()
	mesh.cell_size = 0.25
	mesh.cell_height = 0.25
	var index_of := {}
	var vertices := PackedVector3Array()
	for i in range(0, points.size(), 3):
		var polygon := PackedInt32Array()
		var corners := [to_godot(points[i]), to_godot(points[i + 1]), to_godot(points[i + 2])]
		if (corners[1] - corners[0]).cross(corners[2] - corners[0]).y > 0.0:
			corners.reverse()
		for point: Vector3 in corners:
			var key := point.snapped(Vector3.ONE * 0.001)
			if not index_of.has(key):
				index_of[key] = vertices.size()
				vertices.append(point)
			polygon.append(index_of[key])
		mesh.add_polygon(polygon)
	mesh.vertices = vertices
	return mesh

## ROUTES pairs of triangle centres from random records of the space.
func _route_pairs(records: PackedInt32Array) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var pairs := []
	while pairs.size() < ROUTES:
		var a := _random_centre(records, rng)
		var b := _random_centre(records, rng)
		if a.distance_to(b) > 50.0:
			pairs.append([a, b])
	return pairs

func _random_centre(records: PackedInt32Array, rng: RandomNumberGenerator) -> Vector3:
	var points: PackedVector3Array = reader.get_record_triangle_points(int(records[rng.randi_range(0, records.size() - 1)]))
	var t := rng.randi_range(0, points.size() / 3 - 1) * 3
	return (points[t] + points[t + 1] + points[t + 2]) / 3.0

## A Godot path through query_path, searching at most max_polygons polygons
## (0: unlimited).
func _godot_path(from: Vector3, to: Vector3, max_polygons: int) -> PackedVector3Array:
	var parameters := NavigationPathQueryParameters3D.new()
	parameters.map = map
	parameters.start_position = from
	parameters.target_position = to
	parameters.path_search_max_polygons = max_polygons
	var result := NavigationPathQueryResult3D.new()
	NavigationServer3D.query_path(parameters, result)
	return result.path

func _compare_routes(pairs: Array, max_polygons: int) -> void:
	var godot_ok := 0
	var godot_us := 0
	var godot_length := 0.0
	var ours_ok := 0
	var ours_us := 0
	var ours_length := 0.0
	var both_ok := 0
	for pair in pairs:
		var started := Time.get_ticks_usec()
		var path := _godot_path(to_godot(pair[0]), to_godot(pair[1]), max_polygons)
		godot_us += Time.get_ticks_usec() - started
		var godot_reached := path.size() > 0 and path[path.size() - 1].distance_to(to_godot(pair[1])) < 2.0
		started = Time.get_ticks_usec()
		var route: Dictionary = reader.find_route(space_form_id, pair[0], pair[1], 8.0, true)
		ours_us += Time.get_ticks_usec() - started
		var ours_reached := bool(route.get("found", false))
		if godot_reached:
			godot_ok += 1
			godot_length += _length(path)
		if ours_reached:
			ours_ok += 1
			ours_length += float(route.get("length", 0.0))
		if godot_reached and ours_reached:
			both_ok += 1
		if pair == pairs[0]:
			var target: Vector3 = to_godot(pair[1])
			print("  first pair: Godot path %d points, ends %.1f m from the target (closest map point to the target %.2f m away); ours found %s" % [
				path.size(), path[path.size() - 1].distance_to(target) if path.size() > 0 else -1.0,
				NavigationServer3D.map_get_closest_point(map, target).distance_to(target), ours_reached])
	print("Routes (%d pairs over 50 m apart), Godot searching at most %d polygons (0: unlimited):" % [pairs.size(), max_polygons])
	print("  Godot query_path: reached %d, %.2f ms mean, mean length %.0f m" % [godot_ok, godot_us / 1000.0 / pairs.size(), godot_length / maxi(godot_ok, 1)])
	print("  NavmeshReader.find_route: found %d, %.2f ms mean, mean length %.0f m" % [ours_ok, ours_us / 1000.0 / pairs.size(), ours_length / maxi(ours_ok, 1)])
	print("  reached by both: %d" % both_ok)

func _length(path: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, path.size()):
		total += path[i - 1].distance_to(path[i])
	return total

## 100 avoidance agents walking their Godot paths for AGENT_FRAMES physics
## frames; NavigationServer process time per frame.
func _run_agents(pairs: Array) -> void:
	var agents := []
	for pair in pairs:
		var agent := NavigationServer3D.agent_create()
		NavigationServer3D.agent_set_map(agent, map)
		NavigationServer3D.agent_set_avoidance_enabled(agent, true)
		NavigationServer3D.agent_set_radius(agent, 0.4)
		NavigationServer3D.agent_set_max_speed(agent, 4.0)
		var start := to_godot(pair[0])
		NavigationServer3D.agent_set_position(agent, start)
		agents.append({"rid": agent, "path": _godot_path(start, to_godot(pair[1]), 0), "next": 1, "position": start})
	var total_ms := 0.0
	var peak_ms := 0.0
	for frame in AGENT_FRAMES:
		for entry in agents:
			var path: PackedVector3Array = entry["path"]
			if entry["next"] >= path.size():
				continue
			var to_next: Vector3 = path[entry["next"]] - entry["position"]
			if to_next.length() < 0.5:
				entry["next"] += 1
				continue
			var step := to_next.normalized() * 4.0
			NavigationServer3D.agent_set_velocity(entry["rid"], step)
			entry["position"] += step / Engine.physics_ticks_per_second
			NavigationServer3D.agent_set_position(entry["rid"], entry["position"])
		await get_tree().physics_frame
		var process_ms := Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0
		total_ms += process_ms
		peak_ms = maxf(peak_ms, process_ms)
	print("100 avoidance agents, %d physics frames: navigation process %.3f ms mean, %.3f ms peak per frame" % [AGENT_FRAMES, total_ms / AGENT_FRAMES, peak_ms])
	for entry in agents:
		NavigationServer3D.free_rid(entry["rid"])
