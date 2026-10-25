extends Node3D

var DATA_DIR: String = GameDataConfig.resolve()["data_dir"] ## the launcher's data folder, or GODOTBRYO_DATA_DIR
const CENTER := Vector2i(-17, 0)

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
	var wrld: Dictionary = esm.find_worldspace_by_editor_id("WastelandNV")
	var camera := Camera3D.new()
	add_child(camera)
	camera.global_position = Terrain3DBridge.cell_terrain3d_global_position(CENTER.x, CENTER.y) + Vector3(20.0, 30.0, 20.0)
	camera.make_current()
	await get_tree().process_frame

	var streamer := TerrainStreamer.new()
	streamer.load_radius = 3.0
	streamer.tiles_per_frame = 64
	streamer.configure(esm)
	add_child(streamer)
	streamer.activate(int(wrld["form_id"]))
	var deadline := Time.get_ticks_msec() + 30000
	while (not bool(streamer.get_diagnostics().catalogue_ready) or int(streamer.get_diagnostics().resident_cells) < 29) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	var diagnostics := streamer.get_diagnostics()
	check(int(diagnostics["resident_cells"]) == 29, "radius-3 circular desired set commits the same 29 real cells")

	# Phase 2 publishes complete regions into the fixed domain. Byte parity is
	# covered by test_terrain_region_stager's frozen eight-map oracle hashes.
	var complete_regions := true
	for location: Vector2i in diagnostics.committed_region_locations:
		var actual: Terrain3DRegion = streamer.terrain.data.get_region(location)
		for map_type in range(Terrain3DRegion.TYPE_MAX):
			if actual == null or actual.get_map(map_type) == null or actual.get_map(map_type).get_size() != Vector2i(256, 256):
				complete_regions = false
	check(complete_regions and int(diagnostics.committed_regions) > 0,
			"native worker publishes complete eight-map regions")

	var ready_generation := streamer.get_generation()
	var ready_status := await streamer.await_ready_for(int(wrld["form_id"]), CENTER, ready_generation)
	check(ready_status == TerrainStreamer.ReadyStatus.READY, "already-ready collision area returns READY after a physics frame")
	var immediate_status = await streamer.await_ready_for(int(wrld["form_id"]), CENTER, ready_generation)
	check(immediate_status == TerrainStreamer.ReadyStatus.READY, "subsequent already-ready calls use the cached readiness path")

	var cancel_generation := streamer.get_generation()
	call_deferred("_pause_streamer", streamer)
	var cancel_status := await streamer.await_ready_for(int(wrld["form_id"]), CENTER + Vector2i(10, 0), cancel_generation)
	check(cancel_status == TerrainStreamer.ReadyStatus.CANCELLED, "pause cancels an outstanding readiness wait")
	check(not streamer.visible and not streamer.terrain.visible
			and streamer.terrain.get_collision_mode() == Terrain3DCollision.DISABLED,
			"pause disables terrain visibility, processing, and collision")
	streamer.set_paused(false)
	check(streamer.visible and streamer.terrain.visible and streamer.terrain.is_physics_processing()
			and streamer.terrain.get_collision_mode() == Terrain3DCollision.DYNAMIC_GAME,
			"same-worldspace resume restores camera-driven physics before queue work")
	var supersede_generation := streamer.get_generation()
	call_deferred("_deactivate_streamer", streamer)
	var supersede_status := await streamer.await_ready_for(int(wrld["form_id"]), CENTER + Vector2i(10, 0), supersede_generation)
	check(supersede_status == TerrainStreamer.ReadyStatus.SUPERSEDED, "deactivation supersedes an outstanding readiness wait")

	# Two source-inspection checks lived here, asserting the v0 world_streamer.gd
	# contained no terrain implementation and exactly one terrain call. That file
	# is no longer part of the project, so the assertions had no subject: reading
	# it returned "" and the first check passed vacuously. The separation they
	# guarded is now structural -- v0 is out of the Godot project entirely.
	var coordinator := TransitionCoordinator.new()
	coordinator._generation = 8
	check(not coordinator._can_release_exterior_transition(7, TerrainStreamer.ReadyStatus.READY, true),
			"a stale transition cannot release the player")
	check(not coordinator._can_release_exterior_transition(8, TerrainStreamer.ReadyStatus.CANCELLED, true),
			"cancelled terrain readiness cannot release the player")
	check(not coordinator._can_release_exterior_transition(8, TerrainStreamer.ReadyStatus.READY, false),
			"terrain readiness alone cannot release before objects settle")
	check(coordinator._can_release_exterior_transition(8, TerrainStreamer.ReadyStatus.READY, true),
		"the current transition releases only after object and collision-safe terrain readiness")
	coordinator.free()

	# Unknown/DLC/mod worldspaces must not strand Game's transition await. They
	# are accepted and complete through a no-LAND fallback when this selected
	# master has no terrain catalogue for the destination.
	var unlisted_worldspace := 0x0BADF00D
	streamer.activate(unlisted_worldspace)
	var unlisted_generation := streamer.get_generation()
	var unlisted_deadline := Time.get_ticks_msec() + 10000
	while not bool(streamer.get_diagnostics().catalogue_ready) and Time.get_ticks_msec() < unlisted_deadline:
		await get_tree().process_frame
	var unlisted_status := await streamer.await_ready_for(unlisted_worldspace, CENTER, unlisted_generation)
	check(unlisted_status == TerrainStreamer.ReadyStatus.READY,
		"unlisted worldspace completes a no-LAND readiness fallback instead of freezing the player")

	print("=======================")
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(1 if failures else 0)

func _pause_streamer(streamer: TerrainStreamer) -> void:
	streamer.set_paused(true)

func _deactivate_streamer(streamer: TerrainStreamer) -> void:
	streamer.deactivate()
