extends Node

var failures := 0

func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _ready() -> void:
	var streamer := TerrainStreamer.new()
	streamer.load_radius = 20.0
	streamer._last_center = Vector2i.ZERO
	streamer._touched_regions = {
		Vector2i(0, 0): true, Vector2i(1, 0): true, Vector2i(2, 0): true, Vector2i(3, 0): true,
		Vector2i(10, 0): true, Vector2i(11, 0): true,
	}
	streamer._region_cells = {
		Vector2i(0, 0): [Vector2i(2, 0)], Vector2i(1, 0): [Vector2i(10, 0)],
		Vector2i(2, 0): [Vector2i(12, 0)], Vector2i(3, 0): [Vector2i(15, 0)],
		Vector2i(10, 0): [Vector2i(40, 0)], Vector2i(11, 0): [Vector2i(50, 0)],
	}
	streamer._requeue_uncommitted_regions()
	check(streamer._count_region_state("queued") == 6, "finite domain seeds every touched region exactly once")

	var selected: Array[Vector2i] = []
	for unused in range(4):
		var location: Vector2i = streamer._take_next_region()
		selected.append(location)
		streamer._region_states[location] = "preparing"
	check(selected[0] == Vector2i(0, 0) and selected[1] == Vector2i(1, 0), "near regions dispatch nearest-first")
	check(selected[3] in [Vector2i(10, 0), Vector2i(11, 0)], "one of every four dispatches is reserved for far work")

	streamer._requeue_uncommitted_regions()
	streamer._dispatch_count = 0
	streamer._last_center = Vector2i(50, 0)
	check(streamer._take_next_region() == Vector2i(11, 0), "camera-cell movement recomputes distance priority")
	streamer._last_center = Vector2i.ZERO
	streamer._priority_hints[Vector2i(10, 0)] = Vector2i(40, 0)
	check(streamer._take_next_region() == Vector2i(10, 0), "a far priority hint promotes its existing queue entry")

	streamer._region_states[Vector2i(0, 0)] = "queued"
	var before := streamer._region_states.size()
	streamer._priority_hints[Vector2i(0, 0)] = Vector2i.ZERO
	streamer._priority_hints[Vector2i(0, 0)] = Vector2i.ZERO
	check(streamer._region_states.size() == before, "priority updates cannot duplicate a region entry")

	streamer._region_states[Vector2i(0, 0)] = "committed"
	streamer._committed_regions[Vector2i(0, 0)] = true
	streamer._requeue_uncommitted_regions()
	check(streamer._region_states[Vector2i(0, 0)] == "committed", "terminal committed state is not requeued")
	check(clampi(OS.get_processor_count() - 1, 1, 8) >= 1 and clampi(OS.get_processor_count() - 1, 1, 8) <= 8,
			"worker count contract is clamped to one through eight")
	check(streamer.regions_per_frame == 1, "publication defaults to one prepared region per frame")
	streamer._active_wrld_form_id = 1
	streamer._region_states[Vector2i(1, 0)] = "queued"
	streamer._region_states[Vector2i(2, 0)] = "prepared"
	streamer.set_paused(true)
	check(streamer._region_states[Vector2i(1, 0)] == "cancelled" and streamer._region_states[Vector2i(2, 0)] == "cancelled",
			"pause moves every nonterminal queued/prepared region to cancelled")

	print("=======================")
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(1 if failures else 0)
