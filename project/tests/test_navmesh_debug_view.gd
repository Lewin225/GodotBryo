extends Node3D

## NavmeshReader.get_triangles_near and NavmeshDebugView (TNM). Near the
## Goodsprings alley Sunny Smiles walks (NAVM 00177F71 / 00179B24) the
## accessor returns only triangles within the radius, with record crossings
## (Flags 0x01-0x04), a door triangle (0x0400) and open edges; at
## GoodspringsSource it returns preferred triangles (0x0040). The view cycles
## its modes and builds a mesh for mode 1.

const ALLEY := Vector3(-980.5, 57.0, 119.3)
const GOODSPRINGS_SOURCE := Vector3(-63786.0, -17381.0, 6715.0) / 70.0
const RADIUS := 40.0

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
	_check_alley(reader, wasteland)
	var source: Dictionary = reader.get_triangles_near(wasteland, GOODSPRINGS_SOURCE, RADIUS)
	check(_count_flag(source["flags"], 0x0040) > 0, "GoodspringsSource has preferred triangles (0x0040): %d" % _count_flag(source["flags"], 0x0040))
	_check_view(reader)
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)


func _check_alley(reader: NavmeshReader, wasteland: int) -> void:
	var data: Dictionary = reader.get_triangles_near(wasteland, ALLEY, RADIUS)
	var points: PackedVector3Array = data["points"]
	var flags: PackedInt32Array = data["flags"]
	var cover: PackedInt32Array = data["cover_flags"]
	var open_edges: PackedInt32Array = data["open_edges"]
	check(flags.size() > 100, "the alley returns triangles (%d)" % flags.size())
	check(points.size() == flags.size() * 3 and cover.size() == flags.size() and open_edges.size() == flags.size(), "three points and one of each field per triangle")
	var farthest := 0.0
	for triangle in flags.size():
		var centre := (points[triangle * 3] + points[triangle * 3 + 1] + points[triangle * 3 + 2]) / 3.0
		farthest = maxf(farthest, Vector2(centre.x - ALLEY.x, centre.y - ALLEY.y).length())
	check(farthest <= RADIUS, "every triangle's centre lies within %.0f m in plan (farthest %.1f m)" % [RADIUS, farthest])
	check(_count_flag(flags, 0x07) > 0, "some triangles cross into another record (Flags 0x01-0x04)")
	check(_count_flag(flags, 0x0400) > 0, "the saloon's door triangles are among them (0x0400)")
	var open := 0
	for mask in open_edges:
		if mask != 0:
			open += 1
	check(open > 0, "some triangles have open edges (%d)" % open)


func _check_view(reader: NavmeshReader) -> void:
	var view := NavmeshDebugView.new()
	view.navmesh = reader
	add_child(view)
	check(view.set_mode(-1) == NavmeshDebugView.MODE_NSS, "TNM with no mode goes from off to NSS")
	check(view.set_mode(-1) == NavmeshDebugView.MODE_GODOT, "then to Godot")
	check(view.set_mode(-1) == NavmeshDebugView.MODE_OFF, "then off")
	view.set_mode(NavmeshDebugView.MODE_NSS)
	view._build(EsmServer.find_form_id_by_editor_id("WastelandNV"), ALLEY)
	var mesh := view._mesh_instance.mesh as ArrayMesh
	check(mesh != null and mesh.get_surface_count() == 2, "mode 1 builds triangles and lines near the alley")
	view.set_mode(NavmeshDebugView.MODE_OFF)
	check(view._mesh_instance.mesh == null and not view._legend_layer.visible, "off clears the drawing and the legend")


func _count_flag(flags: PackedInt32Array, mask: int) -> int:
	var count := 0
	for value in flags:
		if value & mask:
			count += 1
	return count
