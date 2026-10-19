extends Node

## BSFurnitureMarker positions in NifServer's tree: one Marker3D per position
## under its owning node, in file order, its offset as the position (metres)
## and the raw orientation and posRef bytes in metadata. Checked against
## Plans/Completed Plans/Actors/census.md A4 (native/tools/furniture_census): SubChairDirty01's
## three markers, the couch's four, the same markers through a flattened
## (prefer_static) tree, and the FURN population, 516 markers over 233 records.

const CHAIR := "Furniture\\Suburban\\SubChairDirty01.NIF"
const COUCH := "Furniture\\Suburban\\SubCouchDirty01.NIF"
const NOT_FURNITURE := "Clutter\\Junk\\Tire01.NIF"
const UNITS_TO_METERS := 1.0 / 70.0
## Census A4's offsets are rounded to 0.1 NIF units.
const TOLERANCE := 0.1 * UNITS_TO_METERS

var failures := 0
var _trees := {}

func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var chair_tree: Node3D = await _tree(CHAIR, false)
	var chair := _markers(chair_tree)
	check(chair.size() == 3, "SubChairDirty01's tree has 3 furniture markers (%d)" % chair.size())
	if chair.size() == 3:
		check(_refs(chair) == [11, 12, 14], "left, right, front: posRef 11, 12, 14 (%s)" % [_refs(chair)])
		check(_near(chair[2].position, Vector3(-2.0, 62.8, -37.2) * UNITS_TO_METERS) and int(chair[2].get_meta("nif_furniture_orientation")) == 3141, "the front marker sits at (-2.0, 62.8, -37.2) units in metres, orientation 3141 raw (%s, %d)" % [chair[2].position, chair[2].get_meta("nif_furniture_orientation")])
		check(chair.all(func(m: Marker3D) -> bool: return m.get_meta("nif_furniture_position_reference_1") == m.get_meta("nif_furniture_position_reference_2")), "posRef1 equals posRef2")
		var flat_tree: Node3D = await _tree(CHAIR, true)
		var flat := _markers(flat_tree)
		check(flat.size() == 3 and _root_position(flat[2], flat_tree).distance_to(_root_position(chair[2], chair_tree)) < 0.0001, "a flattened tree keeps the markers where they were (%d)" % flat.size())
	var couch := _markers(await _tree(COUCH, false))
	check(couch.size() == 4, "SubCouchDirty01's tree has 4 furniture markers (%d)" % couch.size())
	if couch.size() == 4:
		check(_refs(couch).count(14) == 3 and _refs(couch).count(20) == 1, "three front seats (14) and one posRef 20 (%s)" % [_refs(couch)])
		check(_near(couch[2].position, Vector3(-47.6, 71.9, -33.7) * UNITS_TO_METERS), "seat 2 at (-47.6, 71.9, -33.7) units in metres (%s)" % couch[2].position)
	check(_markers(await _tree(NOT_FURNITURE, false)).is_empty(), "a NIF without a marker block has none")
	await _check_population()
	for tree: Node in _trees.values():
		if tree != null:
			tree.free()
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

## Every FURN record's NIF, counted per record as census A4 counts them: 516
## markers over the 233 FURN whose NIF is in the archives.
func _check_population() -> void:
	var markers := 0
	var records := 0
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) != "FURN":
			continue
		var furniture := EsmServer.get_base(int(row["form_id"])) as FurnitureBase
		if furniture == null or furniture.model_path.is_empty():
			continue
		if not ArchiveServer.read("meshes/" + NifServer.canonical(furniture.model_path))["found"]:
			continue
		records += 1
		markers += _markers(await _tree(furniture.model_path, false)).size()
	print("     %d FURN with a NIF, %d markers" % [records, markers])
	check(records == 233 and markers == 516, "the FURN population has 516 markers over 233 records (%d over %d)" % [markers, records])

func _tree(path: String, prefer_static: bool) -> Node3D:
	var key := "%s|%s" % [NifServer.canonical(path), prefer_static]
	if _trees.has(key):
		return _trees[key]
	NifServer.request(path, self, _on_tree.bind(key), prefer_static)
	while not _trees.has(key):
		await get_tree().process_frame
	return _trees[key]

## Parented at once: NifServer frees a tree still unparented a frame later.
func _on_tree(tree: Node3D, key: String) -> void:
	if tree != null:
		add_child(tree)
	_trees[key] = tree

## The tree's furniture markers in file order.
func _markers(tree: Node3D) -> Array[Marker3D]:
	var markers: Array[Marker3D] = []
	if tree == null:
		return markers
	for node in tree.find_children("FurnitureMarker*", "Marker3D", true, false):
		markers.append(node as Marker3D)
	markers.sort_custom(func(a: Marker3D, b: Marker3D) -> bool: return String(a.name).trim_prefix("FurnitureMarker").to_int() < String(b.name).trim_prefix("FurnitureMarker").to_int())
	return markers

## A marker's position in its tree root's space.
func _root_position(marker: Marker3D, root: Node3D) -> Vector3:
	var xform := marker.transform
	var node := marker.get_parent()
	while node != root:
		xform = (node as Node3D).transform * xform
		node = node.get_parent()
	return xform.origin

func _refs(markers: Array[Marker3D]) -> Array:
	return markers.map(func(m: Marker3D) -> int: return int(m.get_meta("nif_furniture_position_reference_1")))

func _near(a: Vector3, b: Vector3) -> bool:
	return a.distance_to(b) <= TOLERANCE * 3.0
