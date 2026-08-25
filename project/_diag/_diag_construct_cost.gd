extends Node3D

const GameDataConfigScript := preload("res://game_data_config.gd")

# TEMP DIAGNOSTIC: measure the main-thread construct-step cost (Node
# creation + DirectGeometryBatch.build()) per tile, at whatever RADIUS_LOAD
# is currently set in world_streamer.gd, for one real activate()-to-settled
# cycle -- to find out whether the single-frame, unbatched construct step
# (introduced by 2.10's threading rework, no longer spread across frames
# the way CellStreamBuilder.stream_refs()'s objects_per_frame used to) is
# what's actually costing frame time now that resolve itself is off-thread.


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
	print("%s: n=%d avg=%.2f median=%.2f p95=%.2f max=%.2f" % [
		label, n, total / n, sorted[n / 2], sorted[int(n * 0.95)], sorted[n - 1]
	])

func _ready() -> void:
	var esm := EsmReader.new()
	if not esm.open(String(GameDataConfigScript.resolve().get("data_dir", "")) + GameDataConfigScript.ESM_FILE):
		push_error("could not open FalloutNV.esm")
		get_tree().quit(1)
		return

	var refr_root := Node3D.new()
	refr_root.rotation_degrees.x = -90
	add_child(refr_root)
	var cam := Camera3D.new()
	refr_root.add_child(cam)
	cam.position = Vector3(-975.8472, 47.89016, 119.7333)
	cam.current = true
	await get_tree().process_frame

	var streamer := WorldStreamer.new()
	add_child(streamer)
	await get_tree().process_frame

	var wrld: Dictionary = esm.find_worldspace_by_editor_id("WastelandNV")
	if wrld.is_empty():
		push_error("WastelandNV not found")
		get_tree().quit(1)
		return

	print("RADIUS_LOAD_DISTANT=%s RADIUS_UNLOAD=%s CHECK_INTERVAL_SEC=%.2f pool_size=%d" % [
		WorldStreamer.RADIUS_LOAD_DISTANT, WorldStreamer.RADIUS_UNLOAD, WorldStreamer.CHECK_INTERVAL_SEC, streamer._pool.get_size()
	])

	var settled_flag := [false]
	var conn := func(): settled_flag[0] = true
	streamer.streaming_settled.connect(conn)
	var t_start := Time.get_ticks_usec()
	streamer.activate(int(wrld["form_id"]))
	var t0 := Time.get_ticks_msec()
	while not settled_flag[0] and Time.get_ticks_msec() - t0 < 60000:
		await get_tree().process_frame
	streamer.streaming_settled.disconnect(conn)
	var t_end := Time.get_ticks_usec()

	print("settled=%s total_wall_time=%.2fms resident_tiles=%d" % [
		settled_flag[0], (t_end - t_start) / 1000.0, streamer._resident.size()
	])
	_percentile_report("construct_ms", streamer.diagnostic_construct_ms)
	_percentile_report("batch_build_ms", streamer.diagnostic_batch_build_ms)
	_percentile_report("terrain_ms", streamer.diagnostic_terrain_ms)
	_percentile_report("resolve_wall_ms", streamer.diagnostic_resolve_wall_ms)
	_percentile_report("refcount_per_tile", streamer.diagnostic_refcounts)

	var totals := { "construct": 0.0, "batch": 0.0, "terrain": 0.0, "resolve_wall": 0.0 }
	for v in streamer.diagnostic_construct_ms:
		totals["construct"] += v
	for v in streamer.diagnostic_batch_build_ms:
		totals["batch"] += v
	for v in streamer.diagnostic_terrain_ms:
		totals["terrain"] += v
	for v in streamer.diagnostic_resolve_wall_ms:
		totals["resolve_wall"] += v
	print("SUM construct=%.2fms SUM batch_build=%.2fms SUM terrain=%.2fms SUM resolve_wall=%.2fms (of %.2fms total wall time)" % [
		totals["construct"], totals["batch"], totals["terrain"], totals["resolve_wall"], (t_end - t_start) / 1000.0
	])

	# The loading-vs-pushing breakdown this used to print here was specific
	# to 2.10's original (unsafe) design, where "pushing" work ran on
	# worker threads too -- that investigation is done and documented
	# (phases/2/10-threaded-streaming-workers.md); GamebryoResolverPool no
	# longer exposes per-stage RS/PS3D timing since that work is now
	# exclusively main-thread (see mesh_resolver.gd's raw/final split).
	print("  find_exterior_cell() total (main thread, _start_tile_load, per newly-entering tile): %.2fms  (%.2fms/tile avg over %d tiles)" % [
		streamer.diagnostic_find_exterior_cell_us / 1000.0, (streamer.diagnostic_find_exterior_cell_us / 1000.0) / streamer._resident.size(), streamer._resident.size()
	])

	get_tree().quit(0)
