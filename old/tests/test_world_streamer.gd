extends Node3D

# phases/2/08-world-cell-streaming.md. Headless test: a real WorldStreamer
# against WastelandNV, driven by a real Camera3D (not the player body --
# get_viewport().get_camera_3d() is what WorldStreamer actually reads).
# Streaming a worldspace's own persistent cell (4468 refs in WastelandNV)
# alongside several resident tiles takes real wall-clock time in this
# headless environment (confirmed: ~220 frame-batches at
# objects_per_frame=20) -- this test's own waits are sized generously
# around that, not tuned to the bare minimum.

const DATA_DIR := "../fresh_nv_copy/Data/"
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

## Real (circular) tile count within `radius` -- WorldStreamer._within_radius()'s
## own definition, reused directly rather than re-derived (e.g. via a
## continuous-circle area formula like pi*r*r, which wouldn't exactly match
## the discrete integer-lattice count WorldStreamer itself produces).
func _count_within_radius(radius: float) -> int:
	var count := 0
	var bound := ceili(radius)
	for dx in range(-bound, bound + 1):
		for dy in range(-bound, bound + 1):
			if WorldStreamer._within_radius(dx, dy, radius):
				count += 1
	return count

func _percentile(values: Array, fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return float(sorted[mini(sorted.size() - 1, floori(float(sorted.size()) * fraction))])

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
	# Not hardcoded -- WorldStreamer.RADIUS_LOAD_DISTANT is tunable (phases/2/08's
	# own explicitly-deferred radius-tuning follow-on), this test should hold
	# at any value. Circular, not a square ring, since WorldStreamer's own
	# radius checks are circular (real distance, not Chebyshev) as of this
	# follow-on -- replicated here via the exact same shared helper
	# WorldStreamer itself uses, not a separately-derived area formula, so
	# this can't silently drift from the real implementation.
	var expected_ring_size := _count_within_radius(WorldStreamer.RADIUS_LOAD_DISTANT)
	check(streamer._resident.size() == expected_ring_size,
			"circular ring (radius %s) resident after settling (got %d, expected %d)" %
			[WorldStreamer.RADIUS_LOAD_DISTANT, streamer._resident.size(), expected_ring_size])
	print("  INFO phase1_object_construct_p95_ms=%.3f max_ms=%.3f samples=%d" % [
		_percentile(streamer.diagnostic_construct_ms, 0.95),
		float(streamer.diagnostic_construct_ms.max()) if not streamer.diagnostic_construct_ms.is_empty() else 0.0,
		streamer.diagnostic_construct_ms.size(),
	])
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

	print("=== phases/2/12-distant-object-lod.md, step 3: full-detail vs distant-only band ===")
	# Center tile (-17,0) is well within RADIUS_LOAD_FULL -- should be
	# streamed full-detail. A tile RADIUS_LOAD_FULL+1 away along a single
	# axis (Chebyshev and real/circular distance are identical for a
	# pure-axis offset -- dy=0 -- so this holds under either metric) is
	# beyond RADIUS_LOAD_FULL but within RADIUS_LOAD_DISTANT, so should be
	# resident but distant-only.
	check(streamer._resident_full_detail.get(Vector2i(-17, 0), false),
			"the camera's own tile was streamed full-detail")
	var distant_coord := Vector2i(int(-17 - WorldStreamer.RADIUS_LOAD_FULL - 1), 0)
	check(streamer._resident.has(distant_coord), "a tile beyond RADIUS_LOAD_FULL but within RADIUS_LOAD_DISTANT is still resident")
	check(not streamer._resident_full_detail.get(distant_coord, true),
			"...but was streamed distant-only, not full-detail (got %s)" % streamer._resident_full_detail.get(distant_coord, true))

	print("=== upgrade-in-place: a distant-only tile becomes full-detail once the camera gets close enough ===")
	var listen_upgrade := _begin_settle_listen(streamer)
	# A small move -- nowhere near RADIUS_UNLOAD -- just enough that
	# distant_coord (distance RADIUS_LOAD_FULL+1 from the original center)
	# falls within RADIUS_LOAD_FULL of the NEW center.
	cam.position.x -= float(WorldStreamer.RADIUS_LOAD_FULL + 1) * cell_size_m
	var settled_upgrade: bool = await _wait_settled(streamer, listen_upgrade)
	check(settled_upgrade, "streaming_settled fired again after the small move")
	check(streamer._resident.has(distant_coord), "the tile is still resident after the small move (never evicted)")
	check(streamer._resident_full_detail.get(distant_coord, false),
			"...and was upgraded to full-detail in place, not left stuck distant-only")

	print("=== downgrade-in-place: a full-detail tile becomes distant-only again once the camera moves far enough away, without being evicted ===")
	# distant_coord is now the resident, full-detail center tile (the camera
	# sits on it after the move above). Move far enough past
	# RADIUS_UNLOAD_FULL that it should downgrade back to distant-only, but
	# nowhere near RADIUS_UNLOAD (13) -- it must stay resident throughout.
	var listen_downgrade := _begin_settle_listen(streamer)
	var downgrade_move_cells := WorldStreamer.RADIUS_UNLOAD_FULL + 2
	cam.position.x += float(downgrade_move_cells) * cell_size_m
	var settled_downgrade: bool = await _wait_settled(streamer, listen_downgrade)
	check(settled_downgrade, "streaming_settled fired again after the further move")
	check(streamer._resident.has(distant_coord), "the tile is still resident after the further move (not evicted)")
	check(not streamer._resident_full_detail.get(distant_coord, true),
			"...but was downgraded back to distant-only, not left stuck full-detail (got %s)" % streamer._resident_full_detail.get(distant_coord, true))

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
	# Must clear RADIUS_LOAD + RADIUS_UNLOAD, not RADIUS_UNLOAD alone -- the
	# closest edge of the OLD resident ring is RADIUS_LOAD cells from the old
	# center, so the camera has to move that far again just to bring that
	# edge back to the old center's own position, before the unload radius
	# even starts counting from the NEW center. Caught directly: a
	# RADIUS_UNLOAD-only margin left a stale band of the old ring resident
	# (504 tiles instead of 441) when RADIUS_LOAD=10/RADIUS_UNLOAD=13.
	var move_cells := WorldStreamer.RADIUS_LOAD_DISTANT + WorldStreamer.RADIUS_UNLOAD + 4
	cam.position.x += float(move_cells) * cell_size_m
	settled = await _wait_settled(streamer, listen2)
	check(settled, "streaming_settled fired again after the move")
	check(not streamer._resident.has(Vector2i(-17, 0)), "the old tile is no longer resident after moving far away")
	check(streamer._resident.size() == expected_ring_size,
			"a full new circular ring (radius %s) is resident after the move (got %d, expected %d)" %
			[WorldStreamer.RADIUS_LOAD_DISTANT, streamer._resident.size(), expected_ring_size])

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
