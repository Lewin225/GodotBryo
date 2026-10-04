class_name LocalNavigation
extends RefCounted

## NavigationServer3D maps holding the NAVM of the cells the streamers have
## loaded: one map per space, one region per NAVM record, and one two-way link
## per derived cross-record pair whose two records both have regions.
## Physicalised actors path on these maps; NpcSimulationServer routes on the
## whole game's NAVM.
##
## A cell's navigation meshes are built on a worker thread and applied on the
## main thread. Maps never use Godot's edge connections: NAVM records do not
## share vertices at their seams, and on a worldspace-sized map Godot's
## free-edge search does not finish (`_diag/diag_navserver_bench`). The links
## join the records instead.

## Emitted on the main thread once a local cell's regions are on its map.
signal cell_ready(cell_form_id: int)

## NavigationMesh and map rasterisation cell size, in metres. At Godot's
## default 0.25, distinct NAVM vertices in GSDocMitchellHouse fall in one
## cell and the map reports an edge error; vertices are already welded
## exactly, so a finer cell loses nothing.
const CELL_SIZE := 0.1
## Gamebryo Z-up to Godot Y-up: (x, y, z) -> (x, z, -y), the basis
## EsmReferencePhysicaliser places references with.
const GAMEBRYO_TO_GODOT_BASIS := Basis(Vector3.RIGHT, -PI / 2.0)

var _navmesh: NavmeshReader
## cell_form_id -> PackedInt32Array of NAVM record indices.
var _records_by_cell: Dictionary = {}
## cell_form_id -> its space's form id, for every cell with NAVM.
var _space_by_cell: Dictionary = {}
## space_form_id -> map RID.
var _maps_by_space: Dictionary = {}
## space_form_id -> { cell_form_id: true } the streamers want local.
var _wanted_cells_by_space: Dictionary = {}
## cell_form_id -> true once its regions are on the map.
var _built_cells: Dictionary = {}
## cell_form_id -> WorkerThreadPool task id, while its meshes are built.
var _build_tasks: Dictionary = {}
## record index -> region RID.
var _regions_by_record: Dictionary = {}
## record index -> Array of link RIDs touching it (each link is listed under
## both of its records).
var _links_by_record: Dictionary = {}
## link RID -> the two record indices it joins.
var _records_by_link: Dictionary = {}

## Indexes the reader's records by cell and builds any cells already wanted.
func set_navmesh(navmesh: NavmeshReader) -> void:
	_navmesh = navmesh
	_records_by_cell.clear()
	_space_by_cell.clear()
	for record_index in navmesh.get_record_count():
		var info: Dictionary = navmesh.get_record_info(record_index)
		var cell_form_id := int(info["cell_form_id"])
		if not _records_by_cell.has(cell_form_id):
			_records_by_cell[cell_form_id] = PackedInt32Array()
			_space_by_cell[cell_form_id] = int(info["space_form_id"])
		var records: PackedInt32Array = _records_by_cell[cell_form_id]
		records.append(record_index)
		_records_by_cell[cell_form_id] = records
	for space_form_id: int in _wanted_cells_by_space:
		for cell_form_id: int in _wanted_cells_by_space[space_form_id]:
			_start_build(cell_form_id)

## Makes `cell_form_ids` the local cells of `space_form_id`: cells no longer
## listed lose their regions and links, new ones are built.
func set_local_cells(space_form_id: int, cell_form_ids: PackedInt32Array) -> void:
	var wanted := {}
	for cell_form_id in cell_form_ids:
		wanted[cell_form_id] = true
	var previous: Dictionary = _wanted_cells_by_space.get(space_form_id, {})
	_wanted_cells_by_space[space_form_id] = wanted
	for cell_form_id: int in previous:
		if not wanted.has(cell_form_id):
			_remove_cell(cell_form_id)
	if _navmesh == null:
		return
	for cell_form_id: int in wanted:
		if not previous.has(cell_form_id):
			_start_build(cell_form_id)

## The navigation map for a space, created empty on first request.
func get_map(space_form_id: int) -> RID:
	if not _maps_by_space.has(space_form_id):
		var map := NavigationServer3D.map_create()
		NavigationServer3D.map_set_cell_size(map, CELL_SIZE)
		NavigationServer3D.map_set_cell_height(map, CELL_SIZE)
		NavigationServer3D.map_set_use_edge_connections(map, false)
		NavigationServer3D.map_set_active(map, true)
		_maps_by_space[space_form_id] = map
	return _maps_by_space[space_form_id]

## Whether a cell's regions are on its map. A cell with no NAVM is never ready.
func is_cell_ready(cell_form_id: int) -> bool:
	return _built_cells.has(cell_form_id)

func get_region_count() -> int:
	return _regions_by_record.size()

func get_link_count() -> int:
	return _records_by_link.size()

## Waits for running builds and frees every map, region and link.
func clear() -> void:
	for task_id: int in _build_tasks.values():
		WorkerThreadPool.wait_for_task_completion(task_id)
	_build_tasks.clear()
	for cell_form_id: int in _built_cells.keys():
		_remove_cell(cell_form_id)
	for map: RID in _maps_by_space.values():
		NavigationServer3D.free_rid(map)
	_maps_by_space.clear()
	_wanted_cells_by_space.clear()

static func to_godot(point: Vector3) -> Vector3:
	return GAMEBRYO_TO_GODOT_BASIS * point

func _is_wanted(cell_form_id: int) -> bool:
	var space_form_id := int(_space_by_cell.get(cell_form_id, 0))
	var wanted: Dictionary = _wanted_cells_by_space.get(space_form_id, {})
	return wanted.has(cell_form_id)

func _start_build(cell_form_id: int) -> void:
	if not _records_by_cell.has(cell_form_id):
		return
	if _built_cells.has(cell_form_id) or _build_tasks.has(cell_form_id):
		return
	var records: PackedInt32Array = _records_by_cell[cell_form_id]
	_build_tasks[cell_form_id] = WorkerThreadPool.add_task(_build_meshes.bind(cell_form_id, records))

## Worker thread: one NavigationMesh per record, then hands them to the main
## thread. Reads only the immutable NavmeshReader.
func _build_meshes(cell_form_id: int, records: PackedInt32Array) -> void:
	var meshes: Array[NavigationMesh] = []
	for record_index in records:
		meshes.append(_navigation_mesh(record_index))
	_apply_build.call_deferred(cell_form_id, records, meshes)

func _apply_build(cell_form_id: int, records: PackedInt32Array, meshes: Array[NavigationMesh]) -> void:
	var task_id: int = _build_tasks.get(cell_form_id, -1)
	_build_tasks.erase(cell_form_id)
	if task_id != -1:
		WorkerThreadPool.wait_for_task_completion(task_id)
	if not _is_wanted(cell_form_id) or _built_cells.has(cell_form_id):
		return
	var map := get_map(int(_space_by_cell[cell_form_id]))
	for index in records.size():
		_add_region(map, records[index], meshes[index])
	_built_cells[cell_form_id] = true
	cell_ready.emit(cell_form_id)

func _add_region(map: RID, record_index: int, mesh: NavigationMesh) -> void:
	var region := NavigationServer3D.region_create()
	NavigationServer3D.region_set_map(region, map)
	NavigationServer3D.region_set_navigation_mesh(region, mesh)
	_regions_by_record[record_index] = region
	_links_by_record[record_index] = []
	_add_links(map, record_index)

## Links from `record_index` to records that already have regions. A pair is
## stored in both directions, so each link is made once: by whichever of its
## two records gets its region second.
func _add_links(map: RID, record_index: int) -> void:
	var cross_links: Dictionary = _navmesh.get_record_cross_links(record_index)
	var points: PackedVector3Array = cross_links["points"]
	var target_records: PackedInt32Array = cross_links["target_records"]
	for index in target_records.size():
		var target_record := target_records[index]
		if target_record == record_index or not _regions_by_record.has(target_record):
			continue
		var link := NavigationServer3D.link_create()
		NavigationServer3D.link_set_map(link, map)
		NavigationServer3D.link_set_bidirectional(link, true)
		NavigationServer3D.link_set_start_position(link, to_godot(points[index * 2]))
		NavigationServer3D.link_set_end_position(link, to_godot(points[index * 2 + 1]))
		_links_by_record[record_index].append(link)
		_links_by_record[target_record].append(link)
		_records_by_link[link] = [record_index, target_record]

func _remove_cell(cell_form_id: int) -> void:
	if not _built_cells.has(cell_form_id):
		return
	_built_cells.erase(cell_form_id)
	for record_index in _records_by_cell[cell_form_id]:
		_remove_region(record_index)

func _remove_region(record_index: int) -> void:
	for link: RID in _links_by_record.get(record_index, []):
		for joined_record: int in _records_by_link[link]:
			if joined_record != record_index:
				_links_by_record[joined_record].erase(link)
		_records_by_link.erase(link)
		NavigationServer3D.free_rid(link)
	_links_by_record.erase(record_index)
	var region: RID = _regions_by_record.get(record_index, RID())
	if region.is_valid():
		NavigationServer3D.free_rid(region)
	_regions_by_record.erase(record_index)

## One record's triangles in Godot axes, vertices welded by position, each
## triangle wound clockwise seen from above.
func _navigation_mesh(record_index: int) -> NavigationMesh:
	var points: PackedVector3Array = _navmesh.get_record_triangle_points(record_index)
	var mesh := NavigationMesh.new()
	mesh.cell_size = CELL_SIZE
	mesh.cell_height = CELL_SIZE
	var vertices := PackedVector3Array()
	var index_by_position := {}
	for first in range(0, points.size(), 3):
		var corners: Array[Vector3] = [to_godot(points[first]), to_godot(points[first + 1]), to_godot(points[first + 2])]
		var normal := (corners[1] - corners[0]).cross(corners[2] - corners[0])
		if normal.y > 0.0:
			corners.reverse()
		var polygon := PackedInt32Array()
		for corner in corners:
			polygon.append(_vertex_index(corner, vertices, index_by_position))
		mesh.add_polygon(polygon)
	mesh.vertices = vertices
	return mesh

func _vertex_index(point: Vector3, vertices: PackedVector3Array, index_by_position: Dictionary) -> int:
	var key := point.snapped(Vector3.ONE * 0.001)
	if not index_by_position.has(key):
		index_by_position[key] = vertices.size()
		vertices.append(point)
	return index_by_position[key]
