extends Node

## NavmeshReader routes across NAVM record seams through the edge NVTR flags
## as crossing into the other record, funnelled with the rest of the route.
##
## Sunny's VCG02SunnyTravelOutside route, from GSProspectorSaloonInterior's
## load door 00108BC7's landing up the alley to VCG02SunnyOutsideMarkerREF,
## crosses from NAVM 00177F71 into 00179B24 at y 58.51 m. Funnelled per
## record with the crossing pinned between the two linked triangles, it turned
## at the seam's west end (-985.67, 58.51) against the alley wall (42.9 m);
## crossing through the flagged edge it rounds the alley corner and crosses
## mid-alley (38.6 m).
##
## Over 40 seeded WastelandNV routes, the share of route length with no navmesh
## beneath it was 16% when flagged edges were read as in-record neighbours and
## 3.2% read as NVEX links.

const DOOR_FORM_ID := 0x00108BC7
const SEAM_WEST_END := Vector2(-985.67, 58.51)
## Metres; the route measured 38.6 m crossing the flagged edge, 42.9 m pinned.
const MAX_SUNNY_ROUTE := 40.0
const BENCH_ROUTES := 40
const BENCH_SEED := 225
## Largest share of bench route length allowed off the navmesh.
const MAX_OFF_MESH_SHARE := 0.05

var failures := 0


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var data_dir := String(preload("res://game_data_config.gd").resolve().get("data_dir", ""))
	var reader := NavmeshReader.new()
	check(reader.load_plugins(PackedStringArray([data_dir + "FalloutNV.esm"])), "NavmeshReader loads FalloutNV.esm")
	var wasteland := EsmServer.find_form_id_by_editor_id("WastelandNV")
	_check_sunny_route(reader, wasteland)
	_check_bench(reader, wasteland)
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _check_sunny_route(reader: NavmeshReader, wasteland: int) -> void:
	var door := EsmServer.get_reference_by_form_id(DOOR_FORM_ID) as DoorReference
	var marker := EsmServer.find_reference_by_editor_id("VCG02SunnyOutsideMarkerREF")
	check(door != null and door.has_teleport and marker != null, "the saloon door 00108BC7 and VCG02SunnyOutsideMarkerREF exist")
	if door == null or marker == null:
		return
	var route: Dictionary = reader.find_route(wasteland, door.teleport_position, marker.position, 8.0, true)
	check(bool(route.get("found", false)), "a route runs from the door's landing to the marker")
	var waypoints: PackedVector3Array = route.get("waypoints", PackedVector3Array())
	var nearest := INF
	for point in waypoints:
		nearest = minf(nearest, Vector2(point.x, point.y).distance_to(SEAM_WEST_END))
	check(nearest > 1.0, "no waypoint at the seam's west end against the alley wall (nearest %.2f m)" % nearest)
	var length := float(route.get("length", INF))
	check(length < MAX_SUNNY_ROUTE, "the route rounds the alley corner and crosses mid-alley (%.1f m, under %.1f m)" % [length, MAX_SUNNY_ROUTE])


func _check_bench(reader: NavmeshReader, wasteland: int) -> void:
	var records: PackedInt32Array = reader.get_records_in_space(wasteland)
	var rng := RandomNumberGenerator.new()
	rng.seed = BENCH_SEED
	var tried := 0
	var found := 0
	var total := 0.0
	var off_mesh := 0.0
	while tried < BENCH_ROUTES:
		var a := _random_centre(reader, records, rng)
		var b := _random_centre(reader, records, rng)
		var distance := a.distance_to(b)
		if distance < 50.0 or distance > 800.0:
			continue
		var start_hit: Dictionary = reader.snap(wasteland, a, 1.0, true)
		var goal_hit: Dictionary = reader.snap(wasteland, b, 1.0, true)
		if int(start_hit.get("component", -1)) != int(goal_hit.get("component", -2)):
			continue
		tried += 1
		var route: Dictionary = reader.find_route(wasteland, a, b, 8.0, true)
		if not bool(route.get("found", false)):
			continue
		found += 1
		total += float(route["length"])
		off_mesh += _off_mesh_metres(reader, wasteland, route["waypoints"])
	check(found == tried, "every bench route within one walkable region is found (%d/%d)" % [found, tried])
	var share := off_mesh / total if total > 0.0 else 1.0
	check(share < MAX_OFF_MESH_SHARE, "bench routes stay on the navmesh: %.1f%% of %.0f m has none beneath it (under %.0f%%)" % [share * 100.0, total, MAX_OFF_MESH_SHARE * 100.0])


## Metres of the route whose 1 m samples have no navmesh within 0.5 m in plan.
func _off_mesh_metres(reader: NavmeshReader, space: int, waypoints: PackedVector3Array) -> float:
	var off := 0.0
	for index in range(1, waypoints.size()):
		var a := waypoints[index - 1]
		var b := waypoints[index]
		var span := Vector2(b.x - a.x, b.y - a.y).length()
		var steps := maxi(1, int(span))
		for step in steps:
			var point := a.lerp(b, (step + 0.5) / steps)
			var hit: Dictionary = reader.snap(space, point, 3.0, true)
			if not bool(hit.get("found", false)):
				off += span / steps
				continue
			var position: Vector3 = hit["position"]
			if Vector2(position.x - point.x, position.y - point.y).length() > 0.5:
				off += span / steps
	return off


func _random_centre(reader: NavmeshReader, records: PackedInt32Array, rng: RandomNumberGenerator) -> Vector3:
	var points: PackedVector3Array = reader.get_record_triangle_points(records[rng.randi_range(0, records.size() - 1)])
	if points.is_empty():
		return Vector3.ZERO
	var first := rng.randi_range(0, points.size() / 3 - 1) * 3
	return (points[first] + points[first + 1] + points[first + 2]) / 3.0
