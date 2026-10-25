extends Node3D

# phases/2/13-terrain3d-integration.md, implementation step 5: physics drop test
# against Terrain3DCollision's built-in collision, answering open question 5 --
# does the same HeightMapShape3D-family failure that made phases/1/04's own
# GamebryoTerrainBuilder abandon HeightMapShape3D (never root-caused, worked around
# via ConcavePolygonShape3D instead) resurface here? Same drop-ball-at-three-points
# methodology as test_terrain_collision.gd, adapted to Terrain3D's own +X/+Z pixel
# convention (see test_terrain3d_spike.gd's header comment -- no reason to inherit
# GamebryoTerrainBuilder's reflected-Z convention for this new placement scheme).

var DATA_DIR: String = GameDataConfig.resolve()["data_dir"] ## the launcher's data folder, or GODOTBRYO_DATA_DIR
const WORLDSPACE_EDITOR_ID := "WastelandNV"
const CELL_GRID_X := -17
const CELL_GRID_Y := 0
const GRID_SIZE := 33

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

func spawn_drop_ball(pos: Vector3) -> RigidBody3D:
	var body := RigidBody3D.new()
	var col := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.1
	col.shape = shape
	body.add_child(col)
	add_child(body)
	body.position = pos
	# Same tunneling risk 1.4 found with a thin, zero-volume terrain collision
	# shape and a fast-moving small body -- see test_terrain_collision.gd.
	body.continuous_cd = true
	return body

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")

	var wrld: Dictionary = esm.find_worldspace_by_editor_id(WORLDSPACE_EDITOR_ID)
	var cell: Dictionary = esm.find_exterior_cell(int(wrld.get("form_id", 0)), CELL_GRID_X, CELL_GRID_Y)
	check(not cell.is_empty(), "found exterior cell (%d, %d)" % [CELL_GRID_X, CELL_GRID_Y])
	if cell.is_empty():
		finish()
		return
	var cell_form_id := int(cell["form_id"])

	var land: Dictionary = esm.get_land_data(cell_form_id)
	var heights: PackedFloat32Array = land.get("heights", PackedFloat32Array())
	check(heights.size() == GRID_SIZE * GRID_SIZE, "heights array is %dx%d" % [GRID_SIZE, GRID_SIZE])
	if heights.size() != GRID_SIZE * GRID_SIZE:
		finish()
		return

	# --- Terrain3D setup + height import (same as test_terrain3d_spike.gd) ---
	var terrain := Terrain3D.new()
	terrain.vertex_spacing = VERTEX_SPACING
	add_child(terrain)
	terrain.region_size = REGION_SIZE as Terrain3D.RegionSize
	if terrain.data == null:
		check(false, "Terrain3D.data initialized")
		finish()
		return

	var height_img := Image.create(GRID_SIZE, GRID_SIZE, false, Image.FORMAT_RF)
	for row in range(GRID_SIZE):
		for col in range(GRID_SIZE):
			height_img.set_pixel(col, row, Color(heights[row * GRID_SIZE + col], 0.0, 0.0, 1.0))
	var images: Array[Image] = []
	images.resize(Terrain3DRegion.TYPE_MAX)
	images[Terrain3DRegion.TYPE_HEIGHT] = height_img
	terrain.data.import_images(images, Vector3.ZERO, 0.0, 1.0)

	# --- Enable real collision (Terrain3DCollision.FULL_GAME builds the whole
	# terrain's collision immediately, synchronously -- confirmed by reading
	# Terrain3DCollision::set_mode()'s source, not assumed). ---
	terrain.collision_mode = Terrain3DCollision.FULL_GAME
	check(terrain.get_collision_mode() == Terrain3DCollision.FULL_GAME, "collision_mode set to FULL_GAME")

	var cam := Camera3D.new()
	add_child(cam)
	var cam_center := Vector3(16.0 * VERTEX_SPACING, 120.0, 16.0 * VERTEX_SPACING)
	cam.global_position = cam_center + Vector3(15.0, 35.0, 30.0)
	cam.look_at(cam_center, Vector3.UP)
	cam.make_current()
	terrain.set_camera(cam)

	# --- Drop at three different grid points, same pattern as
	# test_terrain_collision.gd, adapted to Terrain3D's +X/+Z convention (no
	# world_x/world_z cell-origin offset needed -- imported at Vector3.ZERO). ---
	# Kept away from the imported 33x33 patch's own edges (within a few vertices
	# of col/row 0 or 32, this isolated-cell test's real height data meets
	# Terrain3D's default flat plane in an artificial cliff not present in the
	# actual game -- see test_terrain3d_spike.gd's screenshot). A real streamed
	# scene has neighboring cells there instead of a cliff, so this isn't a
	# collision bug to work around, just a reason to sample away from it here.
	var drop_points := [[8, 4], [20, 12], [16, 20]] # [col, row]
	var balls: Array = []
	var expected: Array = []
	for dp in drop_points:
		var col: int = dp[0]
		var row: int = dp[1]
		var h: float = heights[row * GRID_SIZE + col]
		var expected_world := Vector3(col * VERTEX_SPACING, h, row * VERTEX_SPACING)
		var drop_pos := expected_world + Vector3(0, 3.0, 0)
		balls.append(spawn_drop_ball(drop_pos))
		expected.append(expected_world)

	await get_tree().create_timer(2.0).timeout

	for i in range(balls.size()):
		var ball: RigidBody3D = balls[i]
		var expected_point: Vector3 = expected[i]
		var actual := ball.global_position
		var horiz_err := Vector2(actual.x - expected_point.x, actual.z - expected_point.z).length()
		var vert_err := absf(actual.y - (expected_point.y + 0.1)) # +ball radius resting on flat ground
		print("  drop ", i, ": expected~=", expected_point, " actual=", actual, " horiz_err=", horiz_err, " vert_err=", vert_err)
		# Horizontal tolerance is looser than test_terrain_collision.gd's 0.5m:
		# real measurement here (not assumption) found a tiny 0.1m-radius sphere
		# genuinely rolls up to ~0.9m down real local slope before settling on
		# some Goodsprings terrain points, even well inside the imported patch's
		# interior, well clear of its artificial island edges. Vertical error
		# stayed under 0.2m at every point tested, including the roll cases --
		# this loosened threshold still catches a real placement bug (wrong
		# cell/axis, order-of-magnitude misalignment), just not "did a
		# billiard-ball-radius sphere slide a few tens of cm down a real slope,"
		# which isn't a collision-correctness question.
		check(horiz_err < 2.0, "drop %d: settled within 2m horizontally of its drop column" % i)
		check(vert_err < 1.0, "drop %d: settled within 1m of expected terrain height" % i)

	finish()

func finish() -> void:
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
