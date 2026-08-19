extends Node3D

# phases/2/08-world-cell-streaming.md. Headless test: a real WorldStreamer
# against WastelandNV, driven by a real Camera3D (not the player body --
# get_viewport().get_camera_3d() is what WorldStreamer actually reads).
# Streaming a worldspace's own persistent cell (4468 refs in WastelandNV)
# alongside several resident tiles takes real wall-clock time in this
# headless environment (confirmed: ~220 frame-batches at
# objects_per_frame=20) -- this test's own waits are sized generously
# around that, not tuned to the bare minimum.

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"
const SETTLE_TIMEOUT_MSEC := 90000

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

## Split into a synchronous "start listening" half and an async "wait" half
## -- connecting must happen BEFORE whatever triggers the settle (activate()/
## a camera move), and GDScript requires a coroutine (anything containing
## `await`) to always be called with `await`, so the connect step can't live
## in the same function as the poll loop without forcing the caller to
## `await` connecting too (which would still race the trigger).
func _begin_settle_listen(streamer: WorldStreamer) -> Array:
	# `settled` must be a mutable container (Array), not a plain bool --
	# GDScript lambdas capture local value-type variables BY VALUE, not by
	# reference, so `func(): settled = true` on a plain bool would silently
	# mutate only the lambda's own copy and never propagate back here.
	var settled := [false]
	var conn := func(): settled[0] = true
	streamer.streaming_settled.connect(conn)
	return [settled, conn]

func _wait_settled(streamer: WorldStreamer, listen: Array) -> bool:
	var settled: Array = listen[0]
	var conn: Callable = listen[1]
	var t0 := Time.get_ticks_msec()
	while not settled[0] and Time.get_ticks_msec() - t0 < SETTLE_TIMEOUT_MSEC:
		await get_tree().process_frame
	streamer.streaming_settled.disconnect(conn)
	return settled[0]

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")
	var wrld: Dictionary = esm.find_worldspace_by_editor_id("WastelandNV")
	check(not wrld.is_empty(), "found WastelandNV")
	var wrld_id := int(wrld["form_id"])
	var cell_size_m: float = CellStreamBuilder.CELL_SIZE_UNITS * CellStreamBuilder.GAMEBRYO_UNITS_TO_METERS

	# A real camera, positioned via a REFR's own known XTEL destination
	# (NVCraftsmanHomeDoor's, inside GSProspectorSaloonInterior -- same
	# real data phases/2/07's door-transition fix was verified against),
	# through the same RefrRoot (-90 X) conversion every placed object goes
	# through -- not a synthetic coordinate.
	var refr_root := Node3D.new()
	refr_root.rotation_degrees.x = -90
	add_child(refr_root)
	var cam := Camera3D.new()
	refr_root.add_child(cam)
	cam.position = Vector3(-975.8472, 47.89016, 119.7333)
	cam.current = true
	await get_tree().process_frame # let the viewport register the active camera

	var streamer := WorldStreamer.new()
	add_child(streamer)
	await get_tree().process_frame

	check(not streamer.is_active(), "inactive before the first activate()")

	var coord: Variant = streamer._current_grid_coord()
	check(coord == Vector2i(-17, 0), "world position -> grid coordinate matches the known cell (-17, 0) (got %s)" % [coord])

	print("=== activate(): initial streaming ===")
	var listen := _begin_settle_listen(streamer)
	streamer.activate(wrld_id)
	check(streamer.is_active(), "is_active() true immediately after activate()")
	var settled: bool = await _wait_settled(streamer, listen)
	check(settled, "streaming_settled fired within the timeout")
	check(streamer._resident.size() == 9, "3x3 ring resident after settling (got %d)" % streamer._resident.size())
	check(streamer._resident.has(Vector2i(-17, 0)), "the camera's own tile is resident")
	check(streamer._persistent_root != null, "PersistentRoot was built")

	if streamer._persistent_root != null:
		var pr_refr_root: Node = streamer._persistent_root.get_node("RefrRoot")
		var found_door := false
		for c in pr_refr_root.get_children():
			if c.name == "NVProspectorSaloonDoor":
				found_door = true
		check(found_door, "NVProspectorSaloonDoor (a persistent-cell ref) is in PersistentRoot")

		var duplicate_persistent_roots := 0
		for c in streamer.get_children():
			if c.name == "PersistentRoot":
				duplicate_persistent_roots += 1
		check(duplicate_persistent_roots == 1, "exactly one PersistentRoot exists (got %d)" % duplicate_persistent_roots)

	print("=== movement-driven load/unload ===")
	# Connect BEFORE moving the camera, not after -- _wait_settled()'s own
	# poll loop already spans past CHECK_INTERVAL_SEC's next tick, so no
	# separate wait is needed before it. Connecting after a separate wait
	# would open a real race: if streaming happened to finish inside that
	# wait, the signal would fire before anything was listening yet, and
	# this check would time out despite streaming having genuinely
	# completed correctly (caught directly -- an earlier version of this
	# test did exactly that).
	var listen2 := _begin_settle_listen(streamer)
	cam.position.x += 6.0 * cell_size_m # far enough that every originally-resident tile falls outside the unload radius
	settled = await _wait_settled(streamer, listen2)
	check(settled, "streaming_settled fired again after the move")
	check(not streamer._resident.has(Vector2i(-17, 0)), "the old tile is no longer resident after moving far away")
	check(streamer._resident.size() == 9, "a full new 3x3 ring is resident after the move (got %d)" % streamer._resident.size())

	print("=== deactivate() teardown ===")
	streamer.deactivate()
	await get_tree().process_frame
	await get_tree().process_frame
	check(not streamer.is_active(), "is_active() false after deactivate()")
	check(streamer._resident.is_empty(), "no resident tiles remain")
	check(streamer._persistent_root == null, "PersistentRoot reference cleared")
	check(streamer.get_child_count() == 0, "every child node was actually freed, not just forgotten (got %d remaining)" % streamer.get_child_count())

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
