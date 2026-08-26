extends Node3D

# Contract test for issue #19's Terrain3D batch API spike. This intentionally
# creates only Terrain3D: no Game, WorldStreamer, CellStreamBuilder, REFRs,
# grass, or resolver work can affect the signals observed here.
#
# Current upstream behavior is deliberately recorded, rather than papered over:
# adding a region makes the global region map dirty and emits region_map_changed
# when published; changing an already allocated region's height map publishes the
# height array but does not republish the region map. The future fixed-capacity
# batch API must preserve the latter property for every ordinary LAND update.

var failures: int = 0
var region_map_changes: int = 0
var height_map_changes: int = 0
var all_map_changes: int = 0

func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _on_region_map_changed() -> void:
	region_map_changes += 1

func _on_height_maps_changed() -> void:
	height_map_changes += 1

func _on_maps_changed() -> void:
	all_map_changes += 1

func _ready() -> void:
	var terrain := Terrain3D.new()
	terrain.vertex_spacing = Terrain3DBridge.VERTEX_SPACING
	add_child(terrain)
	terrain.region_size = Terrain3DBridge.REGION_SIZE
	check(terrain.data != null, "Terrain3D data initialized in a blank scene")
	if terrain.data == null:
		finish()
		return

	# Terrain3D's clipmap queries the current camera even in headless mode.
	var camera := Camera3D.new()
	add_child(camera)
	camera.global_position = Vector3(0.0, 100.0, 0.0)
	camera.make_current()
	terrain.set_camera(camera)

	terrain.data.region_map_changed.connect(_on_region_map_changed)
	terrain.data.height_maps_changed.connect(_on_height_maps_changed)
	terrain.data.maps_changed.connect(_on_maps_changed)

	var fixed_locations: Array[Vector2i] = [
		Vector2i(-1, -1), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(0, 0),
	]
	for location in fixed_locations:
		var region: Terrain3DRegion = terrain.data.add_region_blank(location, false)
		check(region != null, "allocated blank region at %s" % location)

	# One explicit publication is the baseline that the issue-19 API replaces.
	terrain.data.update_maps()
	check(region_map_changes == 1, "initial fixed region publication emits one region-map change")
	check(terrain.data.region_locations.size() == fixed_locations.size(), "all fixed regions are published")

	var region_changes_before_edit := region_map_changes
	var height_changes_before_edit := height_map_changes
	var maps_changes_before_edit := all_map_changes

	# This position is inside the already allocated (0, 0) region. It is the
	# important steady-state operation: a LAND write must not cause a global
	# region-map publication (and therefore must not rebuild global collision).
	var edit_position := Vector3(4.0 * Terrain3DBridge.VERTEX_SPACING, 0.0, 4.0 * Terrain3DBridge.VERTEX_SPACING)
	terrain.data.set_height(edit_position, 17.25)
	# Terrain3D's incremental upload API intentionally uses this explicit marker;
	# set_height() modifies the CPU image but does not infer which GPU layer to
	# upload. The issue-19 batch API must preserve this per-region behaviour.
	var edited_region: Terrain3DRegion = terrain.data.get_region(Vector2i(0, 0))
	check(edited_region != null, "edit target resolves to an allocated region")
	if edited_region != null:
		edited_region.set_edited(true)
	terrain.data.update_maps(Terrain3DRegion.TYPE_MAX, false, false)
	if edited_region != null:
		edited_region.set_edited(false)

	check(region_map_changes == region_changes_before_edit,
			"editing an allocated region does not republish the global region map")
	check(height_map_changes > height_changes_before_edit,
			"editing an allocated region republishes its height map")
	check(all_map_changes > maps_changes_before_edit,
			"editing an allocated region notifies Terrain3D materials")
	check(is_equal_approx(terrain.data.get_height(edit_position), 17.25),
			"published height is readable from Terrain3D")

	finish()

func finish() -> void:
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
