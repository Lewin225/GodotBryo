extends Node3D

# TEMP DIAGNOSTIC (untracked scratch tool, same convention as
# _diag_construct_cost.gd): real before/after per-tile terrain cost,
# GamebryoTerrainBuilder vs Terrain3DBridge, for the same real tiles around
# Goodsprings. Calls _stream_tile() directly rather than activate() (which would
# trigger a full RADIUS_LOAD_DISTANT=20 scan -- ~1257 tiles, too much for a first
# real timing check of the new per-vertex Terrain3D path).

const WORLDSPACE_EDITOR_ID := "WastelandNV"

func _percentile_report(label: String, values: Array) -> void:
	if values.is_empty():
		print(label, ": no samples")
		return
	var sorted: Array = values.duplicate()
	sorted.sort()
	var n := sorted.size()
	var total := 0.0
	for v in sorted:
		total += v
	print("%s: n=%d avg=%.2f median=%.2f p95=%.2f max=%.2f sum=%.2f" % [
		label, n, total / n, sorted[n / 2], sorted[int(n * 0.95)], sorted[n - 1], total
	])

func _ready() -> void:
	var tile_coords: Array[Vector2i] = []
	for dx in range(-3, 4):
		for dy in range(-3, 4):
			tile_coords.append(Vector2i(-17 + dx, 0 + dy))
	print("Real tile set: %d tiles" % tile_coords.size())

	await _run_pass(false, tile_coords)
	await _run_pass(true, tile_coords)

	get_tree().quit()

func _run_pass(use_terrain3d: bool, tile_coords: Array[Vector2i]) -> void:
	var streamer := WorldStreamer.new()
	streamer.use_terrain3d = use_terrain3d
	add_child(streamer)
	await get_tree().process_frame # let _ready() run (esm/resolver/_builder setup)
	# This is a fixed 49-tile microbenchmark. Disable the owner's normal
	# camera-driven queue before setting its active-world field for teardown;
	# otherwise its next process frame starts the full 20-cell-radius stream.
	streamer.set_process(false)

	var wrld: Dictionary = streamer.esm.find_worldspace_by_editor_id(WORLDSPACE_EDITOR_ID)
	var wrld_id := int(wrld.get("form_id", 0))
	# _stream_tile() normally runs only after activate(); establish the same
	# lifetime state here so deactivation owns every temporary tile/batch.
	streamer._active_wrld_form_id = wrld_id

	if use_terrain3d:
		streamer._terrain3d = Terrain3DBridge.create_terrain(streamer)
		streamer._terrain3d_pool = Terrain3DTexturePool.new(streamer._terrain3d)
		streamer._terrain3d_bridge = Terrain3DBridge.new(streamer.esm, streamer.resolver, streamer._terrain3d_pool)
		# Keep this direct _stream_tile() diagnostic structurally equivalent to
		# WorldStreamer.activate(): terrain import now immediately discovers and
		# binds grass variants. Omitting this node made the old harness abort each
		# tile at observe_cell(), leaving its terrain timing array empty.
		streamer._terrain_grass_particles = TerrainGrassParticles.new(streamer._terrain3d, streamer._terrain3d_bridge, streamer.esm, streamer.resolver)
		streamer.add_child(streamer._terrain_grass_particles)
		var camera := Camera3D.new()
		streamer.add_child(camera)
		camera.global_position = Terrain3DBridge.cell_terrain3d_global_position(-17, 0) + Vector3(25.0, 20.0, 25.0)
		camera.make_current()
		streamer._terrain3d.set_camera(camera)

	var t0 := Time.get_ticks_msec()
	for coord in tile_coords:
		var cell: Dictionary = streamer.esm.find_exterior_cell(wrld_id, coord.x, coord.y)
		if cell.is_empty():
			continue
		await streamer._stream_tile(int(cell["form_id"]), coord, streamer._generation, true)
	var wall_ms := Time.get_ticks_msec() - t0

	print("\n=== use_terrain3d=%s ===" % use_terrain3d)
	_percentile_report("terrain step (ms)", streamer.diagnostic_terrain_ms)
	print("real tiles resident: %d, total wall time: %d ms" % [streamer._resident.size(), wall_ms])
	if use_terrain3d and streamer._terrain3d_pool != null:
		print("real texture slots used: %d" % streamer._terrain3d_pool.used_slot_count())

	# Use the real ownership cleanup rather than freeing only the Terrain3D
	# child: _stream_tile() also created DirectGeometryBatch RIDs per tile.
	streamer.deactivate()
	streamer.free()
	await get_tree().process_frame
