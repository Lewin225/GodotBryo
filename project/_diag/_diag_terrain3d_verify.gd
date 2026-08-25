extends Node3D

const GameDataConfigScript := preload("res://game_data_config.gd")

# TEMP DIAGNOSTIC: reproduce the spiky-terrain bug reported around cell (-18,0)
# by importing a real grid of cells the same way WorldStreamer does, then
# comparing Terrain3D's own stored height at every real vertex against the
# source LandData.heights for that same cell -- to find exactly which
# cells/vertices disagree, rather than guessing.

const WORLDSPACE_EDITOR_ID := "WastelandNV"
const GRID_SIZE := 33

func _ready() -> void:
	var esm := EsmReader.new()
	esm.open(String(GameDataConfigScript.resolve().get("data_dir", "")) + GameDataConfigScript.ESM_FILE)
	var resolver := GamebryoMeshResolver.new()
	var wrld: Dictionary = esm.find_worldspace_by_editor_id(WORLDSPACE_EDITOR_ID)
	var wrld_id := int(wrld.get("form_id", 0))

	var terrain := Terrain3DBridge.create_terrain(self)
	var pool := Terrain3DTexturePool.new(terrain)
	var bridge := Terrain3DBridge.new(esm, resolver, pool)

	var tile_coords: Array[Vector2i] = []
	for dx in range(-4, 5):
		for dy in range(-4, 5):
			tile_coords.append(Vector2i(-18 + dx, 0 + dy))

	var imported := 0
	var per_cell_heights := {} # Vector2i -> PackedFloat32Array (source data, kept for comparison)
	for coord in tile_coords:
		var cell: Dictionary = esm.find_exterior_cell(wrld_id, coord.x, coord.y)
		if cell.is_empty():
			continue
		var land: Dictionary = esm.get_land_data(int(cell["form_id"]))
		var heights: PackedFloat32Array = land.get("heights", PackedFloat32Array())
		if heights.size() != GRID_SIZE * GRID_SIZE:
			continue
		per_cell_heights[coord] = heights
		if bridge.import_cell(terrain, int(cell["form_id"])):
			imported += 1
	print("imported %d/%d real cells" % [imported, tile_coords.size()])

	var total_checked := 0
	var total_mismatch := 0
	var near_zero_count := 0
	var nan_count := 0
	var worst_err := 0.0
	var worst_info := ""
	var mismatch_cells := {}
	for coord in per_cell_heights.keys():
		var heights: PackedFloat32Array = per_cell_heights[coord]
		var gp := Terrain3DBridge.cell_terrain3d_global_position(coord.x, coord.y)
		for row in range(GRID_SIZE):
			for col in range(GRID_SIZE):
				var expected: float = heights[row * GRID_SIZE + col]
				var pos := Terrain3DBridge.vertex_world_position(gp, row, col)
				var got: float = terrain.data.get_height(pos)
				total_checked += 1
				var err: float = absf(got - expected) if not is_nan(got) else 999999.0
				if err > 0.5:
					total_mismatch += 1
					mismatch_cells[coord] = mismatch_cells.get(coord, 0) + 1
					if is_nan(got):
						nan_count += 1
					elif absf(got) < 5.0:
						near_zero_count += 1
					if err > worst_err:
						worst_err = err
						worst_info = "cell=%s row=%d col=%d expected=%.3f got=%.3f world_pos=%s" % [coord, row, col, expected, got, pos]

	print("checked %d vertices, %d mismatches (>0.5m)" % [total_checked, total_mismatch])
	print("  of which: %d NaN (hole), %d near-zero (<5.0), %d other (leaked/wrong value)" % [nan_count, near_zero_count, total_mismatch - nan_count - near_zero_count])
	print("worst: %s" % worst_info)

	# Is get_height() actually snapping to the exact queried vertex, or silently
	# falling into bilinear interpolation with a neighbor due to float precision?
	# And does the wrong value match a NEIGHBORING vertex's real expected height
	# (an off-by-one indexing bug) rather than something farther away?
	var wc := Vector2i(29, 16) # (col, row) of the worst mismatch above -- cell (-14,-1)
	var wcoord := Vector2i(-14, -1)
	var wheights: PackedFloat32Array = per_cell_heights[wcoord]
	var wgp := Terrain3DBridge.cell_terrain3d_global_position(wcoord.x, wcoord.y)
	print("\n--- neighbor scan around the worst mismatch (cell %s, row=%d, col=%d) ---" % [wcoord, wc.y, wc.x])
	for drow in range(-1, 2):
		for dcol in range(-1, 2):
			var r: int = wc.y + drow
			var c: int = wc.x + dcol
			if r < 0 or r >= GRID_SIZE or c < 0 or c >= GRID_SIZE:
				continue
			var exp_h: float = wheights[r * GRID_SIZE + c]
			var qpos := Terrain3DBridge.vertex_world_position(wgp, r, c)
			var snapped := qpos.snapped(Vector3(Terrain3DBridge.VERTEX_SPACING, 0.0, Terrain3DBridge.VERTEX_SPACING))
			var snap_dist := (qpos - snapped).length()
			print("  (row=%d,col=%d) expected=%.4f query_pos=%s snap_dist=%.8f" % [r, c, exp_h, qpos, snap_dist])
	print("cells with mismatches: %d" % mismatch_cells.size())
	var shown := 0
	for coord in mismatch_cells.keys():
		if shown >= 20:
			print("  ... (%d more)" % (mismatch_cells.size() - shown))
			break
		print("  cell %s: %d bad vertices" % [coord, mismatch_cells[coord]])
		shown += 1

	get_tree().quit()
