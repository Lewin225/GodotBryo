extends Node3D

const DATA_DIR := "../fresh_nv_copy/Data/"
const SETTLE_TIMEOUT_MSEC := 90000
const PHASE1_P95_MS := 2.184
const PHASE1_MAX_MS := 13.594
const ALLOWED_RATIO := 1.10
var failures := 0

func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func percentile(values: Array, fraction: float) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return float(sorted[mini(sorted.size() - 1, floori(float(sorted.size()) * fraction))]) if not sorted.is_empty() else INF

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened real master")
	var resolver := GamebryoMeshResolver.new(DATA_DIR)
	var world: Dictionary = esm.find_worldspace_by_editor_id("WastelandNV")
	var refr_root := Node3D.new()
	refr_root.rotation_degrees.x = -90
	add_child(refr_root)
	var camera := Camera3D.new()
	refr_root.add_child(camera)
	camera.position = Vector3(-975.8472, 47.89016, 119.7333)
	camera.make_current()
	await get_tree().process_frame

	var terrain_streamer := TerrainStreamer.new()
	terrain_streamer.configure(esm, resolver)
	add_child(terrain_streamer)
	var world_streamer := WorldStreamer.new()
	world_streamer.configure(esm, resolver)
	world_streamer.set_terrain_streamer(terrain_streamer)
	add_child(world_streamer)
	await get_tree().process_frame

	var settled := [false]
	world_streamer.streaming_settled.connect(func(): settled[0] = true)
	terrain_streamer.activate(int(world.form_id))
	world_streamer.activate(int(world.form_id))
	var deadline := Time.get_ticks_msec() + SETTLE_TIMEOUT_MSEC
	while not settled[0] and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	check(settled[0], "object ring settles while finite terrain fill is active")

	var values := world_streamer.diagnostic_construct_ms
	var p95 := percentile(values, 0.95)
	var maximum := float(values.max()) if not values.is_empty() else INF
	print("  INFO phase3_object_construct_p95_ms=%.3f max_ms=%.3f samples=%d baseline_p95_ms=%.3f baseline_max_ms=%.3f" % [
		p95, maximum, values.size(), PHASE1_P95_MS, PHASE1_MAX_MS])
	check(p95 <= PHASE1_P95_MS * ALLOWED_RATIO, "object construction p95 remains within 10% of the Phase 1 baseline")
	check(maximum <= PHASE1_MAX_MS * ALLOWED_RATIO, "object construction maximum remains within 10% of the Phase 1 baseline")

	world_streamer.deactivate()
	terrain_streamer.deactivate()
	print("=======================")
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(1 if failures else 0)
