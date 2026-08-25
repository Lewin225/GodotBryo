extends SceneTree

## Reproduces the reported softlock directly: activate() WorldStreamer on
## the real FreesideWorld worldspace with a real camera present (same
## precondition _do_exterior_transition() relies on -- streaming_settled is
## awaited only after the player/camera has already been repositioned), and
## time how long streaming_settled takes to fire, with a generous timeout so
## a genuine hang is reported rather than the script itself hanging forever.

const TIMEOUT_SEC := 25.0

func _init() -> void:
	var esm := EsmReader.new()
	if not esm.open(GamebryoMeshResolver.get_data_dir() + "FalloutNV.esm"):
		push_error("could not open FalloutNV.esm")
		quit(1)
		return
	var wrld: Dictionary = esm.find_worldspace_by_editor_id("FreesideWorld")
	if wrld.is_empty():
		push_error("FreesideWorld not found")
		quit(1)
		return
	var wrld_id := int(wrld["form_id"])

	var scene_root := Node3D.new()
	get_root().add_child(scene_root)

	var cam := Camera3D.new()
	cam.current = true
	# Place the camera near FreesideWorld's own grid center (from the
	# earlier survey: x[-10,6] y[-8,11] -> center roughly (-2, 1)).
	var cell_size_m: float = CellStreamBuilder.CELL_SIZE_UNITS * CellStreamBuilder.GAMEBRYO_UNITS_TO_METERS
	cam.position = Vector3(-2 * cell_size_m, 2.0, -1 * cell_size_m)
	scene_root.add_child(cam)

	var streamer := WorldStreamer.new()
	scene_root.add_child(streamer)
	await process_frame # let WorldStreamer's own _ready() open its EsmReader (matches game.gd's own startup sequencing)

	var settled_flag := [false]
	var conn := func(): settled_flag[0] = true
	streamer.streaming_settled.connect(conn)

	var t0 := Time.get_ticks_msec()
	streamer.activate(wrld_id)

	while not settled_flag[0] and (Time.get_ticks_msec() - t0) / 1000.0 < TIMEOUT_SEC:
		await process_frame

	var elapsed := (Time.get_ticks_msec() - t0) / 1000.0
	var no_cell_note := " no_cell_cache.size=%d" % streamer._no_cell_cache.size() if "_no_cell_cache" in streamer else ""
	var status := "SETTLED" if settled_flag[0] else "TIMEOUT -- NEVER SETTLED"
	print("%s after %.2fs -- resident=%d in_flight=%d load_queue_running=%s load_queue.size=%d%s" % [
		status, elapsed, streamer._resident.size(), streamer._in_flight_count, streamer._load_queue_running, streamer._load_queue.size(), no_cell_note
	])
	quit()
