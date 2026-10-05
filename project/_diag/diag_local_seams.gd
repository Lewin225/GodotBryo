extends Node

## Whether Godot joins exterior NAVM records on its own. A 7 x 7 block of
## WastelandNV cells around Goodsprings (-17, 0) is made local navigation, then
## 100 point pairs in different cells, each routed by NavmeshReader, are pathed
## by Godot with edge connections at several margins. Measured while
## LocalNavigation still built links between derived seam pairs: links only
## reached 94 of 100 (241 m mean against NavmeshReader's 233 m), edge
## connections the same 94 at every margin from 0.25 to 2 m (240-236 m).

const CENTER := Vector2i(-17, 0)
const RADIUS := 3
const PAIRS := 100
const SEED := 7

var local_navigation: LocalNavigation
var wasteland := 0

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	NpcSimulationServer.records_per_frame = 512
	NpcSimulationServer.seed()
	if not NpcSimulationServer.is_seeded:
		await NpcSimulationServer.seed_finished
	wasteland = EsmServer.find_form_id_by_editor_id("WastelandNV")
	local_navigation = NpcSimulationServer.local_navigation
	var cells := PackedInt32Array()
	for dx in range(-RADIUS, RADIUS + 1):
		for dy in range(-RADIUS, RADIUS + 1):
			var cell := EsmServer.get_exterior_cell_form_id(wasteland, CENTER + Vector2i(dx, dy))
			if cell != 0:
				cells.append(cell)
	local_navigation.set_local_cells(wasteland, cells)
	for frame in 600:
		if _all_ready(cells):
			break
		await get_tree().process_frame
	print("%d cells, %d regions" % [cells.size(), local_navigation.get_region_count()])
	var pairs := _pairs(cells)
	print("%d cross-cell pairs NavmeshReader routes" % pairs.size())
	for margin in [0.25, 0.5, 1.0, 2.0]:
		await _run("edge connections, margin %.2f m" % margin, pairs, margin)
	get_tree().quit()

func _all_ready(cells: PackedInt32Array) -> bool:
	for cell in cells:
		if local_navigation._records_by_cell.has(cell) and not local_navigation.is_cell_ready(cell):
			return false
	return true

## Pairs of triangle centres (Gamebryo axes) in different cells that
## NavmeshReader routes between.
func _pairs(cells: PackedInt32Array) -> Array:
	var navmesh := NpcSimulationServer.navmesh
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var records := []
	for cell in cells:
		for record in local_navigation._records_by_cell.get(cell, PackedInt32Array()):
			records.append([cell, record])
	var pairs := []
	var attempts := 0
	while pairs.size() < PAIRS and attempts < PAIRS * 20:
		attempts += 1
		var a: Array = records[rng.randi_range(0, records.size() - 1)]
		var b: Array = records[rng.randi_range(0, records.size() - 1)]
		if a[0] == b[0]:
			continue
		var from := _random_centre(navmesh, a[1], rng)
		var to := _random_centre(navmesh, b[1], rng)
		if bool(navmesh.find_route(wasteland, from, to, 8.0, true).get("found", false)):
			pairs.append([from, to])
	return pairs

func _random_centre(navmesh: NavmeshReader, record: int, rng: RandomNumberGenerator) -> Vector3:
	var points: PackedVector3Array = navmesh.get_record_triangle_points(record)
	var first := rng.randi_range(0, points.size() / 3 - 1) * 3
	return (points[first] + points[first + 1] + points[first + 2]) / 3.0

func _run(label: String, pairs: Array, margin: float) -> void:
	var map := local_navigation.get_map(wasteland)
	NavigationServer3D.map_set_edge_connection_margin(map, margin)
	var started := Time.get_ticks_msec()
	var iteration := NavigationServer3D.map_get_iteration_id(map)
	while NavigationServer3D.map_get_iteration_id(map) == iteration:
		await get_tree().physics_frame
	for frame in 60:
		await get_tree().physics_frame
	var sync_ms := Time.get_ticks_msec() - started
	var reached := 0
	var godot_length := 0.0
	var ours_length := 0.0
	for pair in pairs:
		var from := LocalNavigation.to_godot(pair[0])
		var to := LocalNavigation.to_godot(pair[1])
		var parameters := NavigationPathQueryParameters3D.new()
		parameters.map = map
		parameters.start_position = from
		parameters.target_position = to
		parameters.path_search_max_polygons = 0
		var result := NavigationPathQueryResult3D.new()
		NavigationServer3D.query_path(parameters, result)
		var path := result.path
		if path.size() > 0 and path[path.size() - 1].distance_to(to) < 0.5:
			reached += 1
			godot_length += _length(path)
			ours_length += float(NpcSimulationServer.navmesh.find_route(wasteland, pair[0], pair[1], 8.0, true).get("length", 0.0))
	print("%s: reached %d of %d; Godot %.0f m vs ours %.0f m mean on those; synced in %d ms; edges connected %d" % [
		label, reached, pairs.size(), godot_length / maxi(reached, 1), ours_length / maxi(reached, 1), sync_ms,
		Performance.get_monitor(Performance.NAVIGATION_3D_EDGE_CONNECTION_COUNT)])

func _length(path: PackedVector3Array) -> float:
	var total := 0.0
	for index in range(1, path.size()):
		total += path[index - 1].distance_to(path[index])
	return total
