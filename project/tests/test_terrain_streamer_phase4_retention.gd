extends Node3D

const DATA_DIR := "../fresh_nv_copy/Data/"
const WASTELAND_REGIONS := 292
var failures := 0

func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func wait_until(predicate: Callable, timeout_msec: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_msec
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	return bool(predicate.call())

func map_hash(image: Image) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(image.get_data())
	return context.finish().hex_encode()

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened real master")
	var wasteland: Dictionary = esm.find_worldspace_by_editor_id("WastelandNV")
	var freeside: Dictionary = esm.find_worldspace_by_editor_id("FreesideWorld")
	check(not wasteland.is_empty() and not freeside.is_empty(), "resolved explicit Mojave-family worldspaces")
	var camera := Camera3D.new()
	add_child(camera)
	camera.global_position = Terrain3DBridge.cell_terrain3d_global_position(-17, 0) + Vector3(8, 40, 8)
	camera.make_current()
	var streamer := TerrainStreamer.new()
	streamer.configure(esm, GamebryoMeshResolver.new(DATA_DIR))
	add_child(streamer)
	var catalogued_worldspaces := 0
	for editor_id: String in TerrainStreamer.BASE_GAME_WORLDSPACE_EDITOR_IDS:
		var worldspace := esm.find_worldspace_by_editor_id(editor_id)
		if not worldspace.is_empty() and streamer._cache_family_by_worldspace.get(int(worldspace.form_id), "") == TerrainStreamer.MOJAVE_FAMILY:
			catalogued_worldspaces += 1
	check(catalogued_worldspaces == TerrainStreamer.BASE_GAME_WORLDSPACE_EDITOR_IDS.size(),
		"explicit Mojave catalogue covers every base-master terrain worldspace without FormID inference")

	streamer.activate(int(wasteland.form_id))
	check(await wait_until(func() -> bool:
		var diagnostics := streamer.get_diagnostics()
		return bool(diagnostics.catalogue_ready) and int(diagnostics.committed_regions) == int(diagnostics.total_regions) and int(diagnostics.total_regions) == WASTELAND_REGIONS, 90000),
		"WastelandNV completes before retention round trip")
	var wasteland_terrain := streamer.terrain
	var wasteland_pool := streamer.texture_pool
	var wasteland_bridge := streamer.bridge
	var wasteland_slots := streamer._logical_slots.duplicate()
	var wasteland_staging_count := streamer.diagnostic_staging_ms.size()
	var wasteland_publication_count := streamer.diagnostic_publication_ms.size()
	var sample_location: Vector2i = streamer._committed_regions.keys()[0]
	var wasteland_hash := map_hash(wasteland_terrain.data.get_region(sample_location).get_map(Terrain3DRegion.TYPE_HEIGHT))

	# Different worldspace: source entry must be inactive before destination work starts.
	camera.global_position = Terrain3DBridge.cell_terrain3d_global_position(0, 0) + Vector3(8, 40, 8)
	streamer.activate(int(freeside.form_id))
	check(streamer.terrain != wasteland_terrain and streamer.texture_pool != wasteland_pool and streamer.bridge != wasteland_bridge,
		"Freeside receives independent Terrain3D, bridge, and texture-pool state")
	check(await wait_until(func() -> bool: return bool(streamer.get_diagnostics().catalogue_ready) and int(streamer.get_diagnostics().committed_regions) > 0, 45000),
		"Freeside stages and publishes independently")
	var freeside_before_switch := streamer.get_diagnostics()
	check(int(freeside_before_switch.queued_regions) + int(freeside_before_switch.preparing_regions) + int(freeside_before_switch.prepared_regions) > 0,
		"Freeside has outstanding work to invalidate on the switch back")
	var retained: Dictionary = streamer.get_diagnostics().retained_worldspaces[int(wasteland.form_id)]
	check(retained.cache_family == TerrainStreamer.MOJAVE_FAMILY and not retained.active,
		"outgoing Wasteland entry is retained in the explicit Mojave cache family")
	check(not retained.terrain_visible and not retained.terrain_physics and int(retained.collision_mode) == Terrain3DCollision.DISABLED
			and not retained.grass_processing and int(retained.emitting_emitters) == 0,
		"inactive terrain disables visibility, physics, collision, grass processing, and emitters")
	var inactive_collision_updates := int(retained.collision_updates)
	var inactive_grass_updates := int(retained.grass_coverage_updates)
	for unused in range(30):
		await get_tree().process_frame
	retained = streamer.get_diagnostics().retained_worldspaces[int(wasteland.form_id)]
	check(int(retained.collision_updates) == inactive_collision_updates and int(retained.grass_coverage_updates) == inactive_grass_updates
			and int(retained.emitting_emitters) == 0,
		"inactive entry accumulates zero collision, grass coverage, or emitting-particle work")
	# Freeside remained active while the inactive-Wasteland audit ran above. Take
	# the stale-result baseline immediately before its generation is superseded.
	var freeside_committed_before_switch := int(streamer.get_diagnostics().committed_regions)

	# Return to the original entry. Its maps/bindings must be reused verbatim;
	# a completed queue means no new compose or publication work is permitted.
	camera.global_position = Terrain3DBridge.cell_terrain3d_global_position(-17, 0) + Vector3(8, 40, 8)
	streamer.activate(int(wasteland.form_id))
	check(streamer.terrain == wasteland_terrain and streamer.texture_pool == wasteland_pool and streamer.bridge == wasteland_bridge,
		"return reactivates the original Wasteland terrain, bridge, and texture pool")
	check(streamer._logical_slots == wasteland_slots and map_hash(streamer.terrain.data.get_region(sample_location).get_map(Terrain3DRegion.TYPE_HEIGHT)) == wasteland_hash,
		"retained maps and logical texture mappings are byte-identical on return")
	var return_generation := streamer.get_generation()
	var ready := await streamer.await_ready_for(int(wasteland.form_id), Vector2i(-17, 0), return_generation)
	check(ready == TerrainStreamer.ReadyStatus.READY, "retained terrain restores collision-safe readiness")
	for unused in range(20):
		await get_tree().process_frame
	check(streamer.diagnostic_staging_ms.size() == wasteland_staging_count and streamer.diagnostic_publication_ms.size() == wasteland_publication_count,
		"return to a completed retained worldspace performs no LAND restaging or publication")
	var retained_freeside: Dictionary = streamer.get_diagnostics().retained_worldspaces[int(freeside.form_id)]
	check(int(retained_freeside.committed_regions) == freeside_committed_before_switch,
		"a stale Freeside worker result cannot commit after its generation is superseded (before=%d after=%d)" % [freeside_committed_before_switch, int(retained_freeside.committed_regions)])

	streamer.deactivate()
	for unused in range(10):
		await get_tree().process_frame
	check(streamer.get_diagnostics().retained_worldspaces.is_empty() and streamer.terrain == null,
		"explicit final deactivate releases every retained entry")
	print("=======================")
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(1 if failures == 0 else 1)
