class_name LocalNavigation
extends Node

## Godot navigation for the cells the streamers have loaded: one
## NavigationServer3D map per space and a NavigationRegion3D per NAVM record.
## Physicalised actors path on these maps; NpcSimulationServer routes on the
## whole game's NAVM.
##
## Children are grouped per space (`Space_<form id>`), so the remote scene tree
## and Debug > Visible Navigation show exactly what is local. A cell's
## navigation meshes are built on a worker thread and its nodes added on the
## main thread.
##
## Records join where their open edges meet. Godot's edge connections join
## those within a 0.5 m margin: 82% of NVEX-joined record pairs in
## FalloutNV.esm, and 616 pairs NVEX does not record, 427 of them coincident
## (`native/tools/navm_seam_gap_census.cpp`). A NavigationLink3D joins each
## NVEX-joined pair whose closest open edges are 0.5-4 m apart (72 exterior
## pairs, and the four of interior 0x10D629 at 1.12-3.84 m), between those two
## closest points, so it crosses at the seam. NVEX pairs farther apart (1,062)
## get nothing. Edge connections stall only on a whole
## worldspace's records (`_diag/diag_navserver_bench`), which local maps never
## hold.

## Emitted on the main thread once a local cell's regions are on its map.
signal cell_ready(cell_form_id: int)

## NavigationMesh and map rasterisation cell size, in metres. At Godot's
## default 0.25, distinct NAVM vertices in GSDocMitchellHouse fall in one
## cell and the map reports an edge error; vertices are already welded
## exactly, so a finer cell loses nothing.
const CELL_SIZE := 0.1
## Edge connection margin, metres: joins the slightly misaligned seams that
## would otherwise need a link, well short of the 1 m+ at which unrelated
## edges (a ledge over the ground below) start to join.
const EDGE_CONNECTION_MARGIN := 0.5
## NVEX-joined records whose closest open edges are farther apart than the
## margin, up to this, metres, get a link between those closest points.
const MAX_SEAM_LINK_GAP := 4.0
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
## space_form_id -> the Node3D holding that space's regions and links.
var _roots_by_space: Dictionary = {}
## space_form_id -> { cell_form_id: true } the streamers want local.
var _wanted_cells_by_space: Dictionary = {}
## cell_form_id -> true once its regions are on the map.
var _built_cells: Dictionary = {}
## cell_form_id -> WorkerThreadPool task id, while its meshes are built.
var _build_tasks: Dictionary = {}
## record index -> its NavigationRegion3D.
var _regions_by_record: Dictionary = {}
## record index -> its seam links from NavmeshReader.get_record_seam_links,
## kept while it has a region.
var _seams_by_record: Dictionary = {}
## record index -> the NavigationLink3Ds touching it (each link is listed
## under both of its records).
var _links_by_record: Dictionary = {}
## NavigationLink3D -> the two record indices it joins.
var _records_by_link: Dictionary = {}

func _exit_tree() -> void:
	_wait_for_builds()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_free_maps()

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
		NavigationServer3D.map_set_use_edge_connections(map, true)
		NavigationServer3D.map_set_edge_connection_margin(map, EDGE_CONNECTION_MARGIN)
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

## Waits for running builds and removes every region, link and map.
func clear() -> void:
	_wait_for_builds()
	for cell_form_id: int in _built_cells.keys():
		_remove_cell(cell_form_id)
	_wanted_cells_by_space.clear()
	for root: Node in _roots_by_space.values():
		root.free()
	_roots_by_space.clear()
	_free_maps()

static func to_godot(point: Vector3) -> Vector3:
	return GAMEBRYO_TO_GODOT_BASIS * point

func _wait_for_builds() -> void:
	for task_id: int in _build_tasks.values():
		WorkerThreadPool.wait_for_task_completion(task_id)
	_build_tasks.clear()

func _free_maps() -> void:
	for map: RID in _maps_by_space.values():
		NavigationServer3D.free_rid(map)
	_maps_by_space.clear()

func _is_wanted(cell_form_id: int) -> bool:
	var space_form_id := int(_space_by_cell.get(cell_form_id, 0))
	var wanted: Dictionary = _wanted_cells_by_space.get(space_form_id, {})
	return wanted.has(cell_form_id)

## The node holding a space's regions and links, created on first use.
func _space_root(space_form_id: int) -> Node3D:
	if not _roots_by_space.has(space_form_id):
		var root := Node3D.new()
		root.name = "Space_%X" % space_form_id
		add_child(root)
		_roots_by_space[space_form_id] = root
	return _roots_by_space[space_form_id]

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
	var seams: Array[Dictionary] = []
	for record_index in records:
		meshes.append(_navigation_mesh(record_index))
		seams.append(_navmesh.get_record_seam_links(record_index, EDGE_CONNECTION_MARGIN, MAX_SEAM_LINK_GAP))
	_apply_build.call_deferred(cell_form_id, records, meshes, seams)

func _apply_build(cell_form_id: int, records: PackedInt32Array, meshes: Array[NavigationMesh], seams: Array[Dictionary]) -> void:
	var task_id: int = _build_tasks.get(cell_form_id, -1)
	_build_tasks.erase(cell_form_id)
	if task_id != -1:
		WorkerThreadPool.wait_for_task_completion(task_id)
	if not is_inside_tree() or not _is_wanted(cell_form_id) or _built_cells.has(cell_form_id):
		return
	var space_form_id := int(_space_by_cell[cell_form_id])
	for index in records.size():
		_add_region(space_form_id, records[index], meshes[index], seams[index])
	_built_cells[cell_form_id] = true
	cell_ready.emit(cell_form_id)

func _add_region(space_form_id: int, record_index: int, mesh: NavigationMesh, seams: Dictionary) -> void:
	var region := NavigationRegion3D.new()
	region.name = "NAVM_%08X" % int(_navmesh.get_record_info(record_index)["form_id"])
	region.navigation_mesh = mesh
	region.set_navigation_map(get_map(space_form_id))
	_space_root(space_form_id).add_child(region)
	_regions_by_record[record_index] = region
	_seams_by_record[record_index] = seams
	_links_by_record[record_index] = []
	_add_links(space_form_id, record_index)

## Links from `record_index` to records that already have regions, across the
## seams NavmeshReader found. A seam is found from both of its records, so each
## link is made once: by whichever record gets its region second.
func _add_links(space_form_id: int, record_index: int) -> void:
	var seams: Dictionary = _seams_by_record[record_index]
	var points: PackedVector3Array = seams["points"]
	var target_records: PackedInt32Array = seams["target_records"]
	for index in target_records.size():
		var target_record := target_records[index]
		if not _regions_by_record.has(target_record):
			continue
		var link := NavigationLink3D.new()
		link.name = "Seam_%s_%s" % [_regions_by_record[record_index].name, _regions_by_record[target_record].name]
		link.bidirectional = true
		link.start_position = to_godot(points[index * 2])
		link.end_position = to_godot(points[index * 2 + 1])
		link.set_navigation_map(get_map(space_form_id))
		_space_root(space_form_id).add_child(link)
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
	for link: NavigationLink3D in _links_by_record.get(record_index, []):
		for joined_record: int in _records_by_link[link]:
			if joined_record != record_index:
				_links_by_record[joined_record].erase(link)
		_records_by_link.erase(link)
		link.free()
	_links_by_record.erase(record_index)
	_seams_by_record.erase(record_index)
	var region: NavigationRegion3D = _regions_by_record.get(record_index)
	if region != null:
		region.free()
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
