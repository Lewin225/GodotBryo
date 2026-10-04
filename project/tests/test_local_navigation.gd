extends Node

## Exercises LocalNavigation on real NAVM data: local interior cells become
## NavigationServer3D regions and links that Godot can path across, and stop
## being local without leaving any behind.

const DOC_HOUSE_EDITOR_ID := "GSDocMitchellHouse"
## Physics frames to wait for a map to include newly added regions.
const MAP_SYNC_FRAMES := 120

var failures := 0
var navmesh: NavmeshReader
var local_navigation: LocalNavigation

func _check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	navmesh = NavmeshReader.new()
	var data_dir := String(preload("res://game_data_config.gd").resolve().get("data_dir", ""))
	_check(navmesh.load_plugins(PackedStringArray([data_dir + "FalloutNV.esm"])), "NavmeshReader loads FalloutNV.esm")
	local_navigation = LocalNavigation.new()
	add_child(local_navigation)
	local_navigation.set_navmesh(navmesh)

	await _check_doc_house()
	await _check_linked_interior()
	await _check_cancelled_build()

	local_navigation.clear()
	if failures == 0:
		print("ALL CHECKS PASSED")
		get_tree().quit(0)
	else:
		print("FAILURES: %d" % failures)
		get_tree().quit(1)

func _check_doc_house() -> void:
	var cell := EsmServer.find_form_id_by_editor_id(DOC_HOUSE_EDITOR_ID)
	var records: PackedInt32Array = navmesh.get_records_in_space(cell)
	_check(records.size() > 0, "%s has NAVM (%d records)" % [DOC_HOUSE_EDITOR_ID, records.size()])
	await _make_local(cell)
	_check(local_navigation.get_region_count() == records.size(), "one region per NAVM record (%d)" % local_navigation.get_region_count())
	var from := _triangle_centre(records[0], 0)
	var last_record := records[records.size() - 1]
	var to := _triangle_centre(last_record, _triangle_count(last_record) - 1)
	var path := await _path_when_synced(cell, from, to)
	_check(_reaches(path, to), "a Godot path crosses %s (%d points, %.1f m)" % [DOC_HOUSE_EDITOR_ID, path.size(), _length(path)])
	local_navigation.set_local_cells(cell, PackedInt32Array())
	_check(local_navigation.get_region_count() == 0, "no regions once the house is no longer local")
	_check(not local_navigation.is_cell_ready(cell), "the house is no longer ready")

## An interior whose records are joined by cross-record links: Godot paths
## from one record to another across a link.
func _check_linked_interior() -> void:
	var found := _find_linked_interior()
	_check(not found.is_empty(), "an interior with linked NAVM records exists")
	if found.is_empty():
		return
	var cell: int = found["cell"]
	await _make_local(cell)
	_check(local_navigation.get_link_count() > 0, "interior 0x%X: %d records joined by %d links" % [cell, navmesh.get_records_in_space(cell).size(), local_navigation.get_link_count()])
	var from := _triangle_centre(found["from_record"], 0)
	var to := _triangle_centre(found["to_record"], 0)
	var route: Dictionary = navmesh.find_route(cell, from, to, 8.0, true)
	var path := await _path_when_synced(cell, from, to)
	_check(bool(route.get("found", false)), "NavmeshReader routes between the two records")
	_check(_reaches(path, to), "a Godot path crosses from one record to the other (%d points)" % path.size())
	local_navigation.set_local_cells(cell, PackedInt32Array())
	_check(local_navigation.get_region_count() == 0 and local_navigation.get_link_count() == 0, "no regions or links once the interior is no longer local")

## A cell made local and then not local before its build lands is never built.
func _check_cancelled_build() -> void:
	var cell := EsmServer.find_form_id_by_editor_id(DOC_HOUSE_EDITOR_ID)
	local_navigation.set_local_cells(cell, PackedInt32Array([cell]))
	local_navigation.set_local_cells(cell, PackedInt32Array())
	for frame in 10:
		await get_tree().process_frame
	_check(local_navigation.get_region_count() == 0, "a cancelled build adds no regions")

func _make_local(cell: int) -> void:
	local_navigation.set_local_cells(cell, PackedInt32Array([cell]))
	if not local_navigation.is_cell_ready(cell):
		await local_navigation.cell_ready
	_check(local_navigation.is_cell_ready(cell), "cell 0x%X is ready" % cell)

## The first interior with two records joined by a cross-record link.
func _find_linked_interior() -> Dictionary:
	for space in navmesh.get_space_ids():
		var records: PackedInt32Array = navmesh.get_records_in_space(space)
		if records.size() < 2 or bool(navmesh.get_record_info(records[0])["is_exterior"]):
			continue
		for record in records:
			var targets: PackedInt32Array = navmesh.get_record_cross_links(record)["target_records"]
			for target in targets:
				if target != record and records.has(target):
					return {"cell": space, "from_record": record, "to_record": target}
	return {}

## Waits for the space's map to include its regions, then paths across it.
func _path_when_synced(space: int, from: Vector3, to: Vector3) -> PackedVector3Array:
	var map := local_navigation.get_map(space)
	var path := PackedVector3Array()
	for frame in MAP_SYNC_FRAMES:
		path = NavigationServer3D.map_get_path(map, LocalNavigation.to_godot(from), LocalNavigation.to_godot(to), true)
		if _reaches(path, to):
			break
		await get_tree().physics_frame
	return path

func _reaches(path: PackedVector3Array, authored_target: Vector3) -> bool:
	if path.is_empty():
		return false
	return path[path.size() - 1].distance_to(LocalNavigation.to_godot(authored_target)) < 0.5

func _triangle_count(record: int) -> int:
	return navmesh.get_record_triangle_points(record).size() / 3

func _triangle_centre(record: int, triangle: int) -> Vector3:
	var points: PackedVector3Array = navmesh.get_record_triangle_points(record)
	var first := triangle * 3
	return (points[first] + points[first + 1] + points[first + 2]) / 3.0

func _length(path: PackedVector3Array) -> float:
	var total := 0.0
	for index in range(1, path.size()):
		total += path[index - 1].distance_to(path[index])
	return total
