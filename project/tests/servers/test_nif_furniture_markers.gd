extends Node

## NifServer.request_furniture_markers: BSFurnitureMarker positions from a
## furniture NIF, in file order. Checked against Plans/Actors/census.md A4
## (native/tools/furniture_census): SubChairDirty01's three markers, the couch's
## four, and the whole FURN population, 516 markers over 233 NIFs.

const CHAIR := "Furniture\\Suburban\\SubChairDirty01.NIF"
const COUCH := "Furniture\\Suburban\\SubCouchDirty01.NIF"
const NOT_FURNITURE := "Clutter\\Junk\\Tire01.NIF"
## Census A4's marker offsets are rounded to 0.1 NIF units.
const TOLERANCE := 0.06

var failures := 0
var _results := {}

func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var chair: Array = await _markers(CHAIR)
	check(chair.size() == 3, "SubChairDirty01 has 3 markers (%d)" % chair.size())
	if chair.size() == 3:
		check(_refs(chair) == [11, 12, 14], "left, right, front: posRef 11, 12, 14 (%s)" % [_refs(chair)])
		check(_near(chair[2]["offset"], Vector3(-2.0, 62.8, -37.2)) and int(chair[2]["orientation"]) == 3141, "front marker at (-2.0, 62.8, -37.2), orientation 3141 (%s, %d)" % [chair[2]["offset"], chair[2]["orientation"]])
		check(chair.all(func(m: Dictionary) -> bool: return m["position_reference_1"] == m["position_reference_2"]), "posRef1 equals posRef2")
	var couch: Array = await _markers(COUCH)
	check(couch.size() == 4, "SubCouchDirty01 has 4 markers (%d)" % couch.size())
	if couch.size() == 4:
		check(_refs(couch).count(14) == 3 and _refs(couch).count(20) == 1, "three front seats (14) and one posRef 20 (%s)" % [_refs(couch)])
		check(_near(couch[2]["offset"], Vector3(-47.6, 71.9, -33.7)), "seat 2 at (-47.6, 71.9, -33.7) (%s)" % couch[2]["offset"])
	check((await _markers(NOT_FURNITURE)).is_empty(), "a NIF without a marker block gives none")
	check((await _markers("Furniture\\NoSuchFile.nif")).is_empty(), "a missing NIF gives none")
	var again: Array = await _markers(CHAIR)
	check(again == chair, "a second request returns the cached markers")
	await _check_population()
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

## Every FURN record's NIF, counted per record as census A4 counts them: 516
## markers over the 233 FURN whose NIF is in the archives (234 FURN; 115
## distinct NIFs, shared between records).
func _check_population() -> void:
	var markers := 0
	var records := 0
	var files := {}
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) != "FURN":
			continue
		var furniture := EsmServer.get_base(int(row["form_id"])) as FurnitureBase
		if furniture == null or furniture.model_path.is_empty():
			continue
		var path := NifServer.canonical(furniture.model_path)
		if not ArchiveServer.read("meshes/" + path)["found"]:
			continue
		records += 1
		files[path] = true
		markers += (await _markers(path)).size()
	print("     %d FURN with a NIF, %d distinct NIFs, %d markers" % [records, files.size(), markers])
	check(records == 233 and markers == 516, "the FURN population has 516 markers over 233 records (%d over %d)" % [markers, records])

func _markers(path: String) -> Array:
	_results.erase(path)
	NifServer.request_furniture_markers(path, self, _on_markers.bind(path))
	while not _results.has(path):
		await get_tree().process_frame
	return _results[path]

func _on_markers(markers: Array, path: String) -> void:
	_results[path] = markers

func _refs(markers: Array) -> Array:
	return markers.map(func(m: Dictionary) -> int: return int(m["position_reference_1"]))

func _near(a: Vector3, b: Vector3) -> bool:
	return a.distance_to(b) <= TOLERANCE * 3.0
