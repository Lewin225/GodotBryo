extends Node3D

# Issue #19 native hand-off contract. This scene is intentionally blank: it
# supplies a complete detached map set directly to Terrain3DData and verifies
# that the new atomic publish API has no dependency on WorldStreamer or the
# legacy per-pixel bridge.

var failures: int = 0
var region_map_changes: int = 0
var map_change_counts: Dictionary = {}

func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _on_map_changed(map_name: String) -> void:
	map_change_counts[map_name] = int(map_change_counts.get(map_name, 0)) + 1

func _ready() -> void:
	var terrain := Terrain3D.new()
	terrain.vertex_spacing = Terrain3DBridge.VERTEX_SPACING
	add_child(terrain)
	terrain.region_size = Terrain3DBridge.REGION_SIZE as Terrain3D.RegionSize
	check(terrain.data != null, "Terrain3D initialized")
	if terrain.data == null:
		finish()
		return
	var camera := Camera3D.new()
	add_child(camera)
	camera.make_current()
	terrain.set_camera(camera)

	terrain.data.region_map_changed.connect(func() -> void: region_map_changes += 1)
	for signal_name in ["height_maps_changed", "control_maps_changed", "color_maps_changed",
			"tex_id_a_maps_changed", "tex_id_b_maps_changed", "weight_a_maps_changed",
			"weight_b_maps_changed", "normal_maps_changed"]:
		terrain.data.connect(signal_name, _on_map_changed.bind(signal_name))
	var locations: Array[Vector2i] = [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(0, -1), Vector2i(-1, -1)]
	check(terrain.data.initialize_fixed_region_domain([Vector2i.ZERO, Vector2i.ZERO]) == ERR_INVALID_PARAMETER,
			"fixed domain rejects duplicate locations")
	check(terrain.data.initialize_fixed_region_domain([Vector2i(16, 0)]) == ERR_INVALID_PARAMETER,
			"fixed domain rejects locations outside Terrain3D bounds")
	check(terrain.data.initialize_fixed_region_domain(locations) == OK,
			"fixed domain accepts an unsorted rectangle")
	check(terrain.data.region_locations == [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(0, 0)],
			"fixed layers are deterministic row-major order")
	check(region_map_changes == 1, "fixed-domain initialization publishes the region map once")
	var blank: Terrain3DRegion = terrain.data.get_region(Vector2i(-1, -1))
	var blank_color := blank.get_map(Terrain3DRegion.TYPE_COLOR).get_data()
	var blank_normal := blank.get_map(Terrain3DRegion.TYPE_NORMAL).get_data()
	print("  INFO canonical_color=", Array(blank_color.slice(0, 4)), " canonical_normal=", Array(blank_normal.slice(0, 4)))
	check(Array(blank_color.slice(0, 4)) == [255, 255, 255, 127], "fixed domain uses the canonical color blank")
	check(Array(blank_normal.slice(0, 4)) == [127, 255, 127, 255], "fixed domain uses the canonical world-up normal blank")
	check(terrain.data.initialize_fixed_region_domain(locations) == ERR_ALREADY_IN_USE,
			"fixed domain cannot be initialized twice")
	var maps := _make_staged_maps(Terrain3DBridge.REGION_SIZE, 17.25)
	var location := Vector2i(0, 0)
	check(terrain.data.publish_region_maps(Vector2i(5, 5), maps) == ERR_DOES_NOT_EXIST,
			"publication rejects an unallocated location")
	var invalid_maps := maps.duplicate()
	invalid_maps[0] = Image.create(64, 64, false, Image.FORMAT_RF)
	check(terrain.data.publish_region_maps(location, invalid_maps) == ERR_INVALID_PARAMETER,
			"publication rejects an invalid map size")
	map_change_counts.clear()
	check(terrain.data.publish_region_maps(location, maps) == OK,
			"native API accepts one complete staged region")
	check(terrain.data.region_locations.has(location), "published region is active")
	check(region_map_changes == 1, "first fixed-layer publication does not change the region map")
	check(map_change_counts.size() == 8 and map_change_counts.values().all(func(count: int) -> bool: return count == 1),
			"publication updates each of the eight existing map-array layers exactly once")
	check(is_equal_approx(terrain.data.get_height(Vector3.ZERO), 17.25),
			"published staged height is queryable")

	var replacement := _make_staged_maps(Terrain3DBridge.REGION_SIZE, 33.5)
	map_change_counts.clear()
	check(terrain.data.publish_region_maps(location, replacement) == OK,
			"native API replaces an existing region atomically")
	check(region_map_changes == 1,
			"replacement emits no region-map signal and therefore triggers no connected global collision rebuild")
	check(map_change_counts.size() == 8 and map_change_counts.values().all(func(count: int) -> bool: return count == 1),
			"replacement updates exactly eight existing layers")
	check(is_equal_approx(terrain.data.get_height(Vector3.ZERO), 33.5),
			"replacement height is queryable")
	finish()

func _make_staged_maps(size: int, height: float) -> Array[Image]:
	var maps: Array[Image] = []
	var height_data := PackedByteArray()
	height_data.resize(size * size * 4)
	for offset in range(0, height_data.size(), 4):
		height_data.encode_float(offset, height)
	maps.append(Image.create_from_data(size, size, false, Image.FORMAT_RF, height_data))
	maps.append(Image.create(size, size, false, Image.FORMAT_RF))
	for map_type in range(Terrain3DRegion.TYPE_COLOR, Terrain3DRegion.TYPE_MAX):
		var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
		if map_type == Terrain3DRegion.TYPE_NORMAL:
			image.fill(Color(0.5, 1.0, 0.5, 1.0))
		elif map_type == Terrain3DRegion.TYPE_COLOR:
			image.fill(Color(0.5, 0.5, 0.5, 1.0))
		maps.append(image)
	return maps

func finish() -> void:
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
