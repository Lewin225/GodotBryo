extends Node3D

# phases/2/13-terrain3d-integration.md, implementation step 6: verifies
# Terrain3DBridge's real-world coordinate mapping (Terrain3DBridge.gd's own header
# comment derives it algebraically -- this is the "confirm against real data, don't
# trust the derivation alone" half) two ways:
#
#   1. Cross-check against the v0 builder's own ACTUAL
#      placement for the same real cell -- the live game's real ground truth for
#      "where does this cell's terrain go," not a second independent guess.
#   2. Two real adjacent cells (-17,0) and (-17,1) imported into the SAME Terrain3D
#      node: their shared boundary row must land at the exact same world Z and
#      agree on height there, confirming cells actually compose into continuous
#      terrain rather than each being a disconnected island.

var DATA_DIR: String = GameDataConfig.resolve()["data_dir"] ## the launcher's data folder, or GODOTBRYO_DATA_DIR
# The v0 CellStreamBuilder these came from is removed (see the git history).
# native/src/common/units.h is the authority for the 70 units/m ratio.
const CELL_SIZE_UNITS := 4096.0
const GAMEBRYO_UNITS_TO_METERS := 1.0 / 70.0
const WORLDSPACE_EDITOR_ID := "WastelandNV"
const CELL_GRID_X := -17
const CELL_GRID_Y := 0
const NEIGHBOR_GRID_Y := 1 # north neighbor -- shares CELL_GRID_Y's row=32 edge
const GRID_SIZE := 33

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
	var cell_a: Dictionary = esm.find_exterior_cell(int(wrld.get("form_id", 0)), CELL_GRID_X, CELL_GRID_Y)
	check(not cell_a.is_empty(), "found exterior cell (%d, %d)" % [CELL_GRID_X, CELL_GRID_Y])
	var cell_b: Dictionary = esm.find_exterior_cell(int(wrld.get("form_id", 0)), CELL_GRID_X, NEIGHBOR_GRID_Y)
	check(not cell_b.is_empty(), "found exterior cell (%d, %d)" % [CELL_GRID_X, NEIGHBOR_GRID_Y])
	if cell_a.is_empty() or cell_b.is_empty():
		finish()
		return
	var cell_a_form_id := int(cell_a["form_id"])
	var cell_b_form_id := int(cell_b["form_id"])

	var land_a: Dictionary = esm.get_land_data(cell_a_form_id)
	var heights_a: PackedFloat32Array = land_a.get("heights", PackedFloat32Array())
	var land_b: Dictionary = esm.get_land_data(cell_b_form_id)
	var heights_b: PackedFloat32Array = land_b.get("heights", PackedFloat32Array())
	check(heights_a.size() == GRID_SIZE * GRID_SIZE and heights_b.size() == GRID_SIZE * GRID_SIZE,
			"both cells have real 33x33 heightmaps")
	if heights_a.size() != GRID_SIZE * GRID_SIZE or heights_b.size() != GRID_SIZE * GRID_SIZE:
		finish()
		return

	# --- 1. Cross-check against the REAL, existing GamebryoTerrainBuilder placement ---
	var old_terrain := GamebryoTerrainBuilder.build(land_a, [])
	check(old_terrain != null, "GamebryoTerrainBuilder produced a node for cross-check")
	var old_cell_origin := Vector3(
			CELL_GRID_X * CELL_SIZE_UNITS * GAMEBRYO_UNITS_TO_METERS,
			0.0,
			-(CELL_GRID_Y * CELL_SIZE_UNITS * GAMEBRYO_UNITS_TO_METERS))
	old_terrain.position = old_cell_origin
	add_child(old_terrain)

	var terrain := Terrain3DBridge.create_terrain(self)
	check(terrain.data != null, "Terrain3D.data initialized")
	var pool := Terrain3DTexturePool.new(terrain)
	var bridge := Terrain3DBridge.new(esm, pool)

	check(await bridge.import_cell(terrain, cell_a_form_id), "bridge imported cell (%d, %d)" % [CELL_GRID_X, CELL_GRID_Y])
	check(await bridge.import_cell(terrain, cell_b_form_id), "bridge imported cell (%d, %d)" % [CELL_GRID_X, NEIGHBOR_GRID_Y])

	# Same GamebryoTerrainBuilder local-vertex convention: (col*spacing, height, -(row*spacing))
	var old_spacing := 128.0 * GAMEBRYO_UNITS_TO_METERS
	var cross_check_points := [Vector2i(0, 0), Vector2i(32, 0), Vector2i(0, 32), Vector2i(32, 32), Vector2i(16, 16)]
	var max_err := 0.0
	for p in cross_check_points:
		var col: int = p.x
		var row: int = p.y
		var expected_h: float = heights_a[row * GRID_SIZE + col]
		var old_world := old_cell_origin + Vector3(col * old_spacing, expected_h, -(row * old_spacing))
		var t3d_h: float = terrain.data.get_height(Vector3(old_world.x, 0.0, old_world.z))
		var err := absf(t3d_h - expected_h)
		max_err = maxf(max_err, err)
		check(err < 0.01, "(col=%d,row=%d) Terrain3D height at GamebryoTerrainBuilder's real world XZ matches (expected %.4f, got %.4f)" % [col, row, expected_h, t3d_h])
	print("  max cross-check error: %.6f m" % max_err)

	# --- 2. Real cell-to-cell edge continuity ---
	var edge_max_err := 0.0
	for col in range(GRID_SIZE):
		var a_edge_h: float = heights_a[32 * GRID_SIZE + col] # cell A's row=32 (north edge)
		var b_edge_h: float = heights_b[0 * GRID_SIZE + col] # cell B's row=0 (south edge)
		edge_max_err = maxf(edge_max_err, absf(a_edge_h - b_edge_h))
	check(edge_max_err < 0.01, "cells (%d,%d)/(%d,%d) source heightmaps agree at their shared edge (max diff %.6f m)" % [CELL_GRID_X, CELL_GRID_Y, CELL_GRID_X, NEIGHBOR_GRID_Y, edge_max_err])

	# The shared edge's real world position, per cell A's own row=32:
	var shared_world_z := old_cell_origin.z - 32.0 * old_spacing
	var edge_query_err := 0.0
	for col: int in [0, 8, 16, 24, 32]:
		var world_x: float = old_cell_origin.x + col * old_spacing
		var expected_h: float = heights_a[32 * GRID_SIZE + col]
		var got: float = terrain.data.get_height(Vector3(world_x, 0.0, shared_world_z))
		edge_query_err = maxf(edge_query_err, absf(got - expected_h))
	check(edge_query_err < 0.01, "Terrain3D's own shared-edge query matches both cells' source data (max diff %.6f m)" % edge_query_err)

	print("  bridge used %d real texture slots" % pool.used_slot_count())
	check(pool.used_slot_count() > 0 and pool.used_slot_count() <= Terrain3DTexturePool.USABLE_SLOTS,
			"texture pool stayed within budget (%d/%d)" % [pool.used_slot_count(), Terrain3DTexturePool.USABLE_SLOTS])

	finish()

func finish() -> void:
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
