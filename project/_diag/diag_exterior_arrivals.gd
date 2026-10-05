extends Node3D

## Every placed actor following the player outside GSDocMitchellHouse's front
## door, with a WorldStreamerV2 streaming WastelandNV around the camera there,
## off-screen travel at SPEED times: every 5 s, actors within 20 m of the
## player in the simulation against NpcControllers physicalised under the
## streamer, and of those near actors how many have no node and why. The
## player walks back and forth outside the door at WALK_SPEED over WALK_SPAN.

const SECONDS := 30
const SPEED := 1000.0
const WALK_SPEED := 1.6
const WALK_SPAN := 20.0

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	NpcSimulationServer.records_per_frame = 512
	NpcSimulationServer.seed()
	if not NpcSimulationServer.is_seeded:
		await NpcSimulationServer.seed_finished
	var player := EsmServer.get_player_reference()
	ScriptServer.player_reference = player
	var front_door := EsmServer.get_reference("authored:00103E61") as DoorReference
	var wasteland := front_door.get_teleport_destination_space_form_id()
	ScriptServer.move_reference(player, wasteland, front_door.teleport_position, Vector3.ZERO)
	ScriptServer.apply_pending_moves()
	var camera := Camera3D.new()
	add_child(camera)
	camera.global_position = EsmReferencePhysicaliser.GAMEBRYO_TO_GODOT_BASIS * front_door.teleport_position
	camera.current = true
	var streamer := WorldStreamerV2.new()
	streamer.spawn_reference_types = WorldStreamerV2.SPAWN_REFR | WorldStreamerV2.SPAWN_ACHR
	add_child(streamer)
	await get_tree().process_frame
	streamer.activate(wasteland)
	for frame in 600:
		await get_tree().process_frame
	print("streaming: %d resident tiles" % streamer._resident.size())
	NpcSimulationServer.low_level_travel.speed_scale = SPEED
	var actors: Array = NpcSimulationServer.actors_by_instance_id.values()
	# `-- nofollow` measures the streamer alone, with no actor following.
	if not OS.get_cmdline_user_args().has("nofollow"):
		NpcSimulationServer.package_runner.set_package_for_all(EsmServer.find_base_by_editor_id("DefaultFollowPlayerClose") as PackageBase)
	var started := Time.get_ticks_msec()
	var next_report := 5000
	var origin := player.position
	var frames := 0
	while Time.get_ticks_msec() - started < SECONDS * 1000:
		await get_tree().process_frame
		frames += 1
		var elapsed := Time.get_ticks_msec() - started
		var walked := fmod(elapsed / 1000.0 * WALK_SPEED, WALK_SPAN * 2.0)
		player.position = origin + Vector3(walked if walked < WALK_SPAN else WALK_SPAN * 2.0 - walked, 0.0, 0.0)
		if elapsed < next_report:
			continue
		next_report += 5000
		var near := 0
		var near_with_node := 0
		var reasons := {}
		for actor: ActorReference in actors:
			if actor.current_space_form_id != wasteland or actor.position.distance_to(player.position) >= 20.0:
				continue
			near += 1
			if EsmNode.node_for(actor) != null:
				near_with_node += 1
				continue
			var root := streamer._tile_root_for(actor)
			var reason := "no resident tile"
			if root != null:
				reason = "tile detail %d" % int(root.get_meta("visual_detail", -1))
				if streamer._should_physicalise(actor, int(root.get_meta("visual_detail", -1))):
					reason += ", should physicalise"
			reasons[reason] = int(reasons.get(reason, 0)) + 1
		var controllers := streamer.find_children("*", "NpcController", true, false).size()
		print(NpcSimulationServer.debug_report(20.0))
		print("  %d frames in the last 5 s" % frames)
		frames = 0
		print("  frame: process %.1f ms, physics %.1f ms, navigation %.1f ms; nodes %d; NpcControllers %d" % [
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
			Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0, Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
			streamer.find_children("*", "NpcController", true, false).size()])
		print("t=%2d s: within 20 m %d, with a node %d; NpcControllers under the streamer %d; near without a node: %s" % [elapsed / 1000, near, near_with_node, controllers, reasons])
	NpcSimulationServer.package_runner.set_package_for_all(null)
	get_tree().quit()
