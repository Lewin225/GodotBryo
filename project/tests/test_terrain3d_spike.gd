extends Node3D

# phases/2/13-terrain3d-integration.md, implementation step 2 (spike): import one
# real cell's VHGT heightmap into a Terrain3D region and verify Terrain3D reproduces
# the exact same height data our own GamebryoTerrainBuilder (phases/1/04) reads from
# get_land_data() -- not a visual/eyeball check, a real numeric round-trip.
#
# Deliberately does NOT use GamebryoTerrainBuilder's own (col, -row) placement
# convention -- Terrain3D's own get_pixel() maps image column -> world +X and image
# row -> world +Z directly (confirmed by reading native/terrain3d/src/terrain_3d_data.cpp's
# get_pixel(), not assumed), and there's no reason to inherit the old builder's
# reflected-Z convention for a brand new placement scheme. This test only checks that
# Terrain3D faithfully stores/returns the real heights we hand it, in whatever axis
# convention Terrain3D itself uses.

const DATA_DIR := "../fresh_nv_copy/Data/"
const WORLDSPACE_EDITOR_ID := "WastelandNV"
const CELL_GRID_X := -17
const CELL_GRID_Y := 0
const GRID_SIZE := 33 # esm::kLandGridSize

# phases/2/13-terrain3d-integration.md's chosen region_size=64 + cell-aligned
# vertex_spacing=128 Gamebryo units -> meters (native/src/common/units.h's
# kGamebryoUnitsToMeters, same constant terrain_builder.gd's VERTEX_SPACING uses).
const GAMEBRYO_UNITS_TO_METERS := 1.0 / 70.0
const VERTEX_SPACING := 128.0 * GAMEBRYO_UNITS_TO_METERS
const REGION_SIZE := 64

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")

	var wrld: Dictionary = esm.find_worldspace_by_editor_id(WORLDSPACE_EDITOR_ID)
	check(not wrld.is_empty(), "found worldspace " + WORLDSPACE_EDITOR_ID)

	var cell: Dictionary = esm.find_exterior_cell(int(wrld.get("form_id", 0)), CELL_GRID_X, CELL_GRID_Y)
	check(not cell.is_empty(), "found exterior cell (%d, %d)" % [CELL_GRID_X, CELL_GRID_Y])
	if cell.is_empty():
		finish()
		return

	var land: Dictionary = esm.get_land_data(int(cell["form_id"]))
	check(not land.is_empty(), "found LAND record")
	var heights: PackedFloat32Array = land.get("heights", PackedFloat32Array())
	check(heights.size() == GRID_SIZE * GRID_SIZE, "heights array is %dx%d (%d)" % [GRID_SIZE, GRID_SIZE, heights.size()])
	if heights.size() != GRID_SIZE * GRID_SIZE:
		finish()
		return

	# --- Terrain3D setup ---
	var terrain := Terrain3D.new()
	terrain.vertex_spacing = VERTEX_SPACING
	add_child(terrain) # triggers _initialize() -> terrain.data becomes valid
	terrain.region_size = REGION_SIZE
	check(terrain.data != null, "Terrain3D.data initialized after entering the tree")
	if terrain.data == null:
		finish()
		return

	# --- Build the height image: column -> +X, row -> +Z (Terrain3D's own native
	# mapping, per get_pixel() in terrain_3d_data.cpp) ---
	var height_img := Image.create(GRID_SIZE, GRID_SIZE, false, Image.FORMAT_RF)
	for row in range(GRID_SIZE):
		for col in range(GRID_SIZE):
			height_img.set_pixel(col, row, Color(heights[row * GRID_SIZE + col], 0.0, 0.0, 1.0))

	var images: Array[Image] = [height_img, null, null] # Terrain3DRegion.TYPE_HEIGHT/CONTROL/COLOR order
	terrain.data.import_images(images, Vector3.ZERO, 0.0, 1.0)

	var region_locations: Array = terrain.data.region_locations
	check(region_locations.size() > 0, "import_images created at least one region (%d)" % region_locations.size())

	# Give Terrain3D a camera so its own internal _grab_camera() (clipmap LOD update)
	# doesn't push_error every physics frame under headless -- cosmetic only, but
	# keeps test output free of noise unrelated to the real checks below.
	var cam := Camera3D.new()
	add_child(cam)
	var center := Vector3(16.0 * VERTEX_SPACING, 120.0, 16.0 * VERTEX_SPACING)
	cam.global_position = center + Vector3(15.0, 35.0, 30.0)
	cam.look_at(center, Vector3.UP)
	cam.make_current()
	terrain.set_camera(cam)

	# --- Numeric round-trip: corners, center, and a few interior points ---
	var sample_points := [
		Vector2i(0, 0), Vector2i(GRID_SIZE - 1, 0), Vector2i(0, GRID_SIZE - 1),
		Vector2i(GRID_SIZE - 1, GRID_SIZE - 1), Vector2i(16, 16),
		Vector2i(8, 24), Vector2i(24, 8), Vector2i(5, 27), Vector2i(30, 3),
	]
	var max_abs_error := 0.0
	for p in sample_points:
		var row: int = p.y
		var col: int = p.x
		var expected: float = heights[row * GRID_SIZE + col]
		var world_pos := Vector3(col * VERTEX_SPACING, 0.0, row * VERTEX_SPACING)
		var got: float = terrain.data.get_height(world_pos)
		var err: float = absf(got - expected)
		max_abs_error = maxf(max_abs_error, err)
		check(err < 0.001, "(row=%d,col=%d) height round-trips (expected %.4f, got %.4f, err %.6f)" % [row, col, expected, got, err])
	print("  max abs error across %d sample points: %.6f m" % [sample_points.size(), max_abs_error])

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -30, 0)
	sun.light_energy = 1.3
	add_child(sun)

	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.5, 0.6, 0.75)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.6, 0.65)
	env.ambient_light_energy = 0.8
	env_node.environment = env
	add_child(env_node)

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	if img == null:
		print("  (skipped screenshot -- no real viewport texture under --headless, expected)")
	else:
		const OUT_DIR := "/tmp/nv_test_screenshots/"
		DirAccess.make_dir_recursive_absolute(OUT_DIR)
		var out_path := OUT_DIR + "terrain3d_spike_goodsprings.png"
		var save_err := img.save_png(out_path)
		check(save_err == OK, "saved screenshot to " + out_path)

	finish()

func finish() -> void:
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
