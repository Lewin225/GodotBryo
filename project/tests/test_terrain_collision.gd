extends Node3D

# 1.4 — Exterior Cell + Terrain, terrain collision check. Headless, same
# PhysicsServer3D-doesn't-need-a-GPU pattern as test_collision.gd: drop a
# ball onto the generated ConcavePolygonShape3D terrain collision and
# confirm it settles at the expected height, at the expected horizontal
# position — catching both a vertical scale bug (a ball landing at the
# wrong height) and a horizontal misalignment bug (a ball drifting instead
# of resting directly below its drop point) that a purely visual screenshot
# check could miss.

var DATA_DIR: String = GameDataConfig.resolve()["data_dir"] ## the launcher's data folder, or GODOTBRYO_DATA_DIR
const WORLDSPACE_EDITOR_ID := "WastelandNV"
const CELL_GRID_X := -17
const CELL_GRID_Y := 0
const CELL_SIZE_UNITS := 4096.0
const GAMEBRYO_UNITS_TO_METERS := 1.0 / 70.0
const VERTEX_SPACING := 128.0 * GAMEBRYO_UNITS_TO_METERS

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
	# A small, fast body dropped from height onto a zero-thickness trimesh
	# (this terrain collision has no volume) can tunnel straight through
	# with discrete collision detection — see phases/1/04-exterior-cell-terrain.md.
	body.continuous_cd = true
	return body

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")

	var wrld: Dictionary = esm.find_worldspace_by_editor_id(WORLDSPACE_EDITOR_ID)
	var cell: Dictionary = esm.find_exterior_cell(int(wrld.get("form_id", 0)), CELL_GRID_X, CELL_GRID_Y)
	check(not cell.is_empty(), "found exterior cell (%d, %d)" % [CELL_GRID_X, CELL_GRID_Y])
	var cell_form_id := int(cell["form_id"])

	var world := Node3D.new()
	world.rotation_degrees.x = -90
	add_child(world)

	var land: Dictionary = esm.get_land_data(cell_form_id)
	check(not land.is_empty(), "found LAND record")
	var heights: PackedFloat32Array = land.get("heights", PackedFloat32Array())

	var terrain := GamebryoTerrainBuilder.build(land, [])
	check(terrain != null, "terrain builder produced a node")
	# Terrain is built natively Y-up (see terrain_builder.gd) — placed as a
	# sibling of "world", NOT a child of it (world's -90 X rotation is only
	# for the Bethesda-Z-up REFR/NIF pipeline).
	var world_x := CELL_GRID_X * CELL_SIZE_UNITS * GAMEBRYO_UNITS_TO_METERS
	var world_z := -(CELL_GRID_Y * CELL_SIZE_UNITS * GAMEBRYO_UNITS_TO_METERS)
	terrain.position = Vector3(world_x, 0.0, world_z)
	add_child(terrain)

	# Drop at three different grid points (not just the corner) so a
	# purely-linear bug (right scale, wrong origin) wouldn't accidentally
	# pass at one point only.
	var drop_points := [[8, 4], [20, 12], [30, 28]] # [col, row]
	var balls: Array = []
	var expected: Array = []
	for dp in drop_points:
		var col: int = dp[0]
		var row: int = dp[1]
		var h: float = heights[row * 33 + col]
		var expected_world := Vector3(world_x + col * VERTEX_SPACING, h, world_z - row * VERTEX_SPACING)
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
		check(horiz_err < 0.5, "drop %d: settled within 0.5m horizontally of its drop column" % i)
		check(vert_err < 1.0, "drop %d: settled within 1m of expected terrain height" % i)

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
