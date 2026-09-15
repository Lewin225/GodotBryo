extends Node3D

const SETTLE_TIMEOUT_MSEC := 15000

var failures := 0


func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1


func _await_settled(streamer: WorldStreamerV2) -> bool:
	var settled := [false]
	var callback := func() -> void: settled[0] = true
	streamer.streaming_settled.connect(callback)
	var deadline := Time.get_ticks_msec() + SETTLE_TIMEOUT_MSEC
	while not settled[0] and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if streamer.streaming_settled.is_connected(callback):
		streamer.streaming_settled.disconnect(callback)
	return settled[0]


func _ready() -> void:
	var esm_server = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var world: Dictionary = esm_server.reader.find_worldspace_by_editor_id("WastelandNV")
	check(not world.is_empty(), "found WastelandNV through EsmServer's reader")
	if world.is_empty():
		get_tree().quit(1)
		return

	var camera := Camera3D.new()
	add_child(camera)
	# The known Goodsprings exterior destination in Godot world coordinates.
	camera.global_position = Vector3(-975.8472, 119.7333, -47.89016)
	camera.current = true
	await get_tree().process_frame

	var streamer := WorldStreamerV2.new()
	check(is_equal_approx(streamer.load_radius, 4.0), "V2 defaults to a doubled, Inspector-tunable four-cell load radius")
	check(is_equal_approx(streamer.lod_load_radius, 8.0), "V2 defaults to a wider, Inspector-tunable paired-LOD radius")
	streamer.tiles_per_frame = 1
	streamer.objects_per_frame = 1
	add_child(streamer)
	await get_tree().process_frame
	var actor_reference := ActorReference.new()
	var creature_reference := CreatureReference.new()
	var ordinary_reference := EsmReference.new()
	streamer.spawn_reference_types = WorldStreamerV2.SPAWN_REFR
	check(not streamer._should_spawn(actor_reference) and not streamer._should_spawn(creature_reference), "ACHR and CREA flags independently suppress legacy actor spawning")
	check(streamer._should_spawn(ordinary_reference), "REFR flag retains ordinary physicalisation")
	check(streamer._detail_for_offset(0, 0) == EsmNode.VisualDetail.FULL, "the camera tile is full detail")
	check(streamer._detail_for_offset(5, 0) == EsmNode.VisualDetail.LOD, "the outer resident ring requests paired LOD")
	check(not streamer._should_physicalise(ordinary_reference, EsmNode.VisualDetail.LOD), "non-VWD REFRs do not enter the LOD-only ring")
	ordinary_reference.visible_when_distant = true
	check(streamer._should_physicalise(ordinary_reference, EsmNode.VisualDetail.LOD), "VWD REFRs enter the LOD-only ring")
	check(not streamer._should_physicalise(actor_reference, EsmNode.VisualDetail.LOD), "actor assembly never enters the generic LOD-only ring")
	var non_vwd_reference := EsmReference.new()
	var membership_tile := Node3D.new()
	var vwd_node := EsmNode.new()
	vwd_node.configure(ordinary_reference)
	var non_vwd_node := EsmNode.new()
	non_vwd_node.configure(non_vwd_reference)
	membership_tile.add_child(vwd_node)
	membership_tile.add_child(non_vwd_node)
	streamer._prune_tile_to_lod(membership_tile)
	check(membership_tile.get_child_count() == 1 and membership_tile.get_child(0) == vwd_node,
		"a full-to-LOD tile transition removes resident non-VWD nodes")
	membership_tile.set_meta("visual_detail", EsmNode.VisualDetail.LOD)
	membership_tile.set_meta("grid_coord", Vector2i.ZERO)
	membership_tile.set_meta("references", [ordinary_reference, non_vwd_reference])
	streamer._set_tile_visual_detail(membership_tile, EsmNode.VisualDetail.FULL)
	check(not streamer._tile_population_jobs.is_empty() or not streamer._persistent_population_jobs.is_empty(),
		"an LOD-to-full tile transition queues omitted references for physicalisation")
	streamer._tile_population_jobs.clear()
	streamer._persistent_population_jobs.clear()
	membership_tile.free()
	streamer.spawn_reference_types = WorldStreamerV2.SPAWN_REFR | WorldStreamerV2.SPAWN_ACHR | WorldStreamerV2.SPAWN_CREA
	check(streamer._current_grid_coord() == Vector2i(-17, 0), "active camera maps to the known exterior grid tile")
	streamer._load_queue.append_array([Vector2i(-23, 0), Vector2i(-18, 0), Vector2i(-20, 0)])
	streamer._persistent_load_queue.append_array([Vector2i(-21, 0), Vector2i(-19, 0)])
	streamer._sort_tile_start_queues(Vector2i(-17, 0))
	check(streamer._load_queue[0] == Vector2i(-18, 0) and streamer._persistent_load_queue[0] == Vector2i(-19, 0),
		"queued tile starts are reordered by current camera distance")
	var population_jobs: Array[Dictionary] = [
		{"coord": Vector2i(-24, 0)},
		{"coord": Vector2i(-18, 0)},
		{"coord": Vector2i(-20, 0)},
	]
	check(streamer._closest_population_job_index(population_jobs, Vector2i(-17, 0)) == 1,
		"incremental population chooses the nearest queued tile")
	streamer._load_queue.clear()
	streamer._persistent_load_queue.clear()
	var persistent_only_root := Node3D.new()
	streamer._persistent_population_jobs.append({
		"coord": Vector2i(-19, 0),
		"root": persistent_only_root,
		"references": [],
		"next_index": 0,
		"generation": streamer._generation,
	})
	streamer._process_population()
	check(streamer._persistent_population_jobs.is_empty(),
		"a persistent-only population queue never selects an invalid regular-job index")
	persistent_only_root.free()

	streamer.activate(int(world.form_id))
	check(streamer.is_active(), "active immediately after activate()")
	check(await _await_settled(streamer), "initial semantic residency settles without awaiting NIF callbacks")
	check(streamer._resident.has(Vector2i(-17, 0)), "camera tile has a resident semantic root")
	check(streamer._persistent_root != null, "persistent references have a dedicated semantic root")
	check(streamer._persistent_imposter_root != null and streamer._persistent_imposter_root.get_child_count() == 0 \
		and not streamer._persistent_imposter_queue.is_empty(),
		"persistent XSRF/XSRD imposters wait behind nearby semantic tile work")
	await get_tree().process_frame
	var tile_root: Node3D = streamer._resident.get(Vector2i(-17, 0))
	var physicalised: EsmNode = tile_root.get_child(0) as EsmNode if tile_root != null and tile_root.get_child_count() > 0 else null
	check(physicalised != null, "physicalizer incrementally populated the resident tile")
	if physicalised != null:
		var converted_position := Basis(Vector3.RIGHT, -PI / 2.0) * physicalised.reference.position
		check(physicalised.transform.origin.is_equal_approx(converted_position), "EsmNode converts its authored placement into Godot space")
		check(physicalised.get_authored_transform().origin.is_equal_approx(physicalised.reference.position), "authored transform inverts placement conversion for future dirty checks")

	streamer.set_paused(true, false)
	check(streamer.is_paused() and streamer.visible and not streamer.is_pause_hiding(),
		"plain pause retains visible exterior geometry and collision state")
	streamer.set_paused(true)
	check(streamer.is_paused() and not streamer.visible and streamer.is_pause_hiding(),
		"Pause & Hide retains roots while suppressing the exterior")
	streamer.activate(int(world.form_id))
	check(await _await_settled(streamer), "same-worldspace resume emits settlement again for Game's player-release handshake")
	check(not streamer.is_paused(), "activate() resumes the retained worldspace")

	streamer.deactivate()
	check(not streamer.is_active() and streamer._resident.is_empty(), "deactivate frees v2 semantic tile roots")
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
