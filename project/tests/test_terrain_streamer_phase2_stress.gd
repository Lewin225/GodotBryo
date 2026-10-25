extends Node3D

var DATA_DIR: String = GameDataConfig.resolve()["data_dir"] ## the launcher's data folder, or GODOTBRYO_DATA_DIR
var failures := 0

func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened real master")
	var world: Dictionary = esm.find_worldspace_by_editor_id("WastelandNV")
	var camera := Camera3D.new()
	add_child(camera)
	camera.global_position = Terrain3DBridge.cell_terrain3d_global_position(-17, 0) + Vector3(8, 40, 8)
	camera.make_current()
	var streamer := TerrainStreamer.new()
	streamer.load_radius = 2.0
	streamer.configure(esm)
	add_child(streamer)
	streamer.activate(int(world.form_id))
	check(not streamer._is_collision_area_committed(Vector2i(-17, 0)),
			"readiness stays closed until the native catalogue and required regions exist")
	# Supersede the initial catalogue task and resume before it completes. The
	# stale index must be reaped and a current-generation index must restart.
	await get_tree().process_frame
	streamer.set_paused(true)
	streamer.set_paused(false)

	var deadline := Time.get_ticks_msec() + 30000
	var query_count := 0
	while (not bool(streamer.get_diagnostics().catalogue_ready) or int(streamer.get_diagnostics().committed_regions) < 4) and Time.get_ticks_msec() < deadline:
		camera.global_position.x += 0.05
		if streamer.terrain != null and streamer.terrain.data != null:
			streamer.terrain.data.get_height(camera.global_position)
			streamer.terrain.collision.update(false)
			query_count += 1
		await get_tree().process_frame
	check(query_count > 0 and Time.get_ticks_msec() < deadline,
			"worker staging remains safe during rendering, height/collision queries, and camera motion")
	var diagnostics := streamer.get_diagnostics()
	check(int(diagnostics.committed_regions) > 0, "complete regions published under stress")
	var publication: Array = diagnostics.publication_ms
	publication.sort()
	var p95 := float(publication[mini(publication.size() - 1, floori(publication.size() * 0.95))]) if not publication.is_empty() else INF
	print("  INFO publication_p95_ms=%.3f samples=%d" % [p95, publication.size()])
	check(p95 < 16.67, "steady-state main-thread publication p95 stays within one frame")

	# Force new work, then invalidate its generation while detached composition
	# may still be active. No result from that generation may publish.
	camera.global_position = Terrain3DBridge.cell_terrain3d_global_position(40, 0) + Vector3(8, 40, 8)
	streamer.request_terrain_priority(Vector2i(40, 0))
	var generation_before_pause := streamer.get_generation()
	streamer.set_paused(true)
	var committed_at_pause := int(streamer.get_diagnostics().committed_regions)
	for i in range(10): await get_tree().process_frame
	check(streamer.get_generation() != generation_before_pause and int(streamer.get_diagnostics().committed_regions) == committed_at_pause,
			"pause rejects stale worker publication and advances generation")
	streamer.set_paused(false)
	check(streamer.terrain.visible and streamer.terrain.is_physics_processing(), "resume restores the live Terrain3D before work")
	deadline = Time.get_ticks_msec() + 10000
	while int(streamer.get_diagnostics().committed_regions) <= committed_at_pause and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	check(int(streamer.get_diagnostics().committed_regions) > committed_at_pause,
			"resume restarts queued work after a stale completion")

	streamer.request_terrain_priority(Vector2i(-30, 0))
	streamer.deactivate()
	deadline = Time.get_ticks_msec() + 5000
	while int(streamer.get_diagnostics().abandoned_workers) > 0 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	check(not streamer.is_active() and streamer.terrain == null and int(streamer.get_diagnostics().committed_regions) == 0,
			"deactivation discards detached results without recreating scene resources")
	check(int(streamer.get_diagnostics().abandoned_workers) == 0, "detached worker resources are safely reaped")
	finish()

func finish() -> void:
	print("=======================")
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(1 if failures else 0)
