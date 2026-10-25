extends Node3D

# 2.11 — Exterior Cell Lookup Index. See
# phases/2/11-exterior-cell-lookup-index.md.

var DATA_DIR: String = GameDataConfig.resolve()["data_dir"] ## the launcher's data folder, or GODOTBRYO_DATA_DIR

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

	var wrld: Dictionary = esm.find_worldspace_by_editor_id("WastelandNV")
	check(not wrld.is_empty(), "found WastelandNV")
	var wrld_id := int(wrld["form_id"])

	print("=== round-trip: find_exterior_cell() -> get_exterior_cell_grid() agrees on coordinate ===")
	# Real coordinates across several different blocks -- deliberately
	# ASYMMETRIC (x != y) ones, not just the easy x==y cases that hid the
	# GRUP-label x/y swap bug this task found (block (0,0)'s own cells are
	# all x==y, which made an earlier broken version of this fix pass a
	# less rigorous check). Also covers negative coordinates (a real,
	# common case -- Goodsprings' own block is negative) and a
	# worldspace-edge miss.
	var real_coords := [
		Vector2i(-17, 0),  # Goodsprings -- this codebase's own WorldStreamer fixture
		Vector2i(7, 15), Vector2i(7, 23), Vector2i(15, 7), # asymmetric, block (0,0)
		Vector2i(-25, 39), Vector2i(39, -57), # asymmetric, different blocks entirely
		Vector2i(-18, 0), Vector2i(-18, 1), Vector2i(-17, -1), Vector2i(-17, 1), # Goodsprings' own neighbors
	]
	for coord in real_coords:
		var cell: Dictionary = esm.find_exterior_cell(wrld_id, coord.x, coord.y)
		check(not cell.is_empty(), "found a cell at grid %s" % [coord])
		if not cell.is_empty():
			var grid: Dictionary = esm.get_exterior_cell_grid(int(cell["form_id"]))
			check(not grid.is_empty() and int(grid["x"]) == coord.x and int(grid["y"]) == coord.y,
					"round-trips to the same coordinate %s (got %s)" % [coord, grid])

	print("=== worldspace-edge miss: no cell at a coordinate far outside any real block ===")
	var far_cell: Dictionary = esm.find_exterior_cell(wrld_id, 10000, 10000)
	check(far_cell.is_empty(), "no cell found at a coordinate far beyond the worldspace's real extent")

	print("=== (0,0): must resolve to the REAL grid tile, not the persistent cell's own placeholder XCLC ===")
	# Caught directly during this task's own verification: the worldspace's
	# persistent cell record carries a placeholder XCLC of (0,0) even
	# though it isn't a real grid tile at all -- the OLD linear-scan
	# implementation hit it first (file order) and silently returned it
	# instead of the real cell at (0,0), for as long as this function has
	# existed. A cell with real terrain (a LAND child) distinguishes the
	# genuine grid tile from the persistent bucket, which has none.
	var origin_cell: Dictionary = esm.find_exterior_cell(wrld_id, 0, 0)
	check(not origin_cell.is_empty(), "found a cell at (0,0)")
	if not origin_cell.is_empty():
		var land: Dictionary = esm.get_land_data(int(origin_cell["form_id"]))
		check(not land.is_empty(), "(0,0)'s resolved cell has real terrain -- it's the genuine grid tile, not the persistent cell")

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
