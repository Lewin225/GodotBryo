extends SceneTree

# TEMP DIAGNOSTIC: for each real cell in a grid, compute which Terrain3D region
# locations it needs (replicating Terrain3DBridge's own internal math via its real
# static helpers) and check whether any region is claimed by more than 4 cells
# (the max possible for a genuine 2x2-cells-per-region sharing pattern at
# region_size=64) -- a real over-claim would mean two UNRELATED cells think they
# share a region that should be exclusive to a different 2x2 group, which would
# explain one cell's real height writes getting silently discarded/overwritten by
# another's add_region_blank() call.

func _initialize():
	call_deferred("_run")

func _run():
	var region_to_cells := {} # Vector2i -> Array[Vector2i cell coords]
	for dx in range(-4, 5):
		for dy in range(-4, 5):
			var gx := -18 + dx
			var gy := 0 + dy
			var cell_span := 32
			var x0 := gx * cell_span
			var x1 := x0 + cell_span
			var z0 := -gy * cell_span - cell_span
			var z1 := -gy * cell_span
			var rx := [Terrain3DBridge._floor_div(x0, 64), Terrain3DBridge._floor_div(x1, 64)]
			var rz := [Terrain3DBridge._floor_div(z0, 64), Terrain3DBridge._floor_div(z1, 64)]
			var seen := {}
			for a in rx:
				for b in rz:
					var loc := Vector2i(a, b)
					if seen.has(loc):
						continue
					seen[loc] = true
					if not region_to_cells.has(loc):
						region_to_cells[loc] = []
					region_to_cells[loc].append(Vector2i(gx, gy))

	var over_claimed := 0
	for loc in region_to_cells.keys():
		var cells: Array = region_to_cells[loc]
		if cells.size() > 4:
			over_claimed += 1
			print("OVER-CLAIMED region %s: %d cells: %s" % [loc, cells.size(), cells])

	print("total regions touched: %d, over-claimed (>4 cells): %d" % [region_to_cells.size(), over_claimed])

	# Also print the region breakdown for the two adjacent cells from the earlier
	# passing 2-cell test, and for the specific failing cell, to sanity check by eye.
	for gx_gy in [Vector2i(-17, 0), Vector2i(-17, 1), Vector2i(-14, -1)]:
		for loc in region_to_cells.keys():
			if region_to_cells[loc].has(gx_gy):
				print("cell %s is in region %s alongside %s" % [gx_gy, loc, region_to_cells[loc]])

	quit()
