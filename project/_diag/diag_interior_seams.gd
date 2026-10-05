extends Node

## Which edge connection margin joins interior 0x10D629's five NAVM records:
## a Godot path between every pair of records NavmeshReader routes between
## (first triangle centre to first triangle centre), per margin.

const CELL := 0x10D629

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	NpcSimulationServer.records_per_frame = 512
	NpcSimulationServer.seed()
	if not NpcSimulationServer.is_seeded:
		await NpcSimulationServer.seed_finished
	var local_navigation := NpcSimulationServer.local_navigation
	var navmesh := NpcSimulationServer.navmesh
	local_navigation.set_local_cells(CELL, PackedInt32Array([CELL]))
	if not local_navigation.is_cell_ready(CELL):
		await local_navigation.cell_ready
	var records: PackedInt32Array = navmesh.get_records_in_space(CELL)
	var pairs := []
	for a in records:
		for b in records:
			if a < b:
				var from := _centre(navmesh, a)
				var to := _centre(navmesh, b)
				if bool(navmesh.find_route(CELL, from, to, 8.0, true).get("found", false)):
					pairs.append([from, to, a, b])
	var map := local_navigation.get_map(CELL)
	for margin in [0.25, 0.5, 1.0, 2.0, 4.0]:
		NavigationServer3D.map_set_edge_connection_margin(map, margin)
		for frame in 60:
			await get_tree().physics_frame
		var reached := []
		for pair in pairs:
			var to := LocalNavigation.to_godot(pair[1])
			var path := NavigationServer3D.map_get_path(map, LocalNavigation.to_godot(pair[0]), to, true)
			if path.size() > 0 and path[path.size() - 1].distance_to(to) < 0.5:
				reached.append("%d-%d" % [pair[2], pair[3]])
		print("margin %.2f m: %d of %d record pairs joined %s" % [margin, reached.size(), pairs.size(), reached])
	get_tree().quit()

func _centre(navmesh: NavmeshReader, record: int) -> Vector3:
	var points: PackedVector3Array = navmesh.get_record_triangle_points(record)
	return (points[0] + points[1] + points[2]) / 3.0
