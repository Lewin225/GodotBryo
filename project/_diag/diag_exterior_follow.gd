extends Node

## Every placed actor following the player (DefaultFollowPlayerClose) while
## the player stands outside GSDocMitchellHouse's front door in WastelandNV,
## off-screen travel at SPEED times: sampled every 5 s, how many actors are
## within 20 m of the player, how many are in WastelandNV, the simulation
## thread's queue, routes and door sequences answered and not found, and the
## mean time a route job took on the thread. The player walks back and forth
## outside the door at WALK_SPEED over WALK_SPAN, as a player does.

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
	NpcSimulationServer.low_level_travel.speed_scale = SPEED
	var counts := {"routes": 0, "routes_failed": 0, "sequences": 0, "sequences_empty": 0}
	NpcSimulationServer.route_ready.connect(func(_id: int, result: Dictionary) -> void:
		counts["routes"] += 1
		if not bool(result.get("found", false)):
			counts["routes_failed"] += 1)
	NpcSimulationServer.door_sequence_ready.connect(func(_id: int, portals: Array) -> void:
		counts["sequences"] += 1
		if portals.is_empty():
			counts["sequences_empty"] += 1)
	var actors: Array = NpcSimulationServer.actors_by_instance_id.values()
	var in_wasteland_at_start := 0
	for actor: ActorReference in actors:
		if actor.current_space_form_id == wasteland:
			in_wasteland_at_start += 1
	print("%d actors, %d of them in WastelandNV at the start" % [actors.size(), in_wasteland_at_start])
	NpcSimulationServer.package_runner.set_script_package_for_all(EsmServer.find_base_by_editor_id("DefaultFollowPlayerClose") as PackageBase)
	var started := Time.get_ticks_msec()
	var next_report := 5000
	var origin := player.position
	while Time.get_ticks_msec() - started < SECONDS * 1000:
		await get_tree().physics_frame
		var elapsed := Time.get_ticks_msec() - started
		var walked := fmod(elapsed / 1000.0 * WALK_SPEED, WALK_SPAN * 2.0)
		player.position = origin + Vector3(walked if walked < WALK_SPAN else WALK_SPAN * 2.0 - walked, 0.0, 0.0)
		if elapsed < next_report:
			continue
		next_report += 5000
		var near := 0
		var in_wasteland := 0
		var stuck_no_route := 0
		for actor: ActorReference in actors:
			if actor.current_space_form_id != wasteland:
				continue
			in_wasteland += 1
			if actor.position.distance_to(player.position) < 20.0:
				near += 1
			var route: Dictionary = NpcSimulationServer.low_level_travel._routes.get(actor, {})
			if actor.has_move_target and not route.is_empty() and route["request_id"] == -1 and (route["waypoints"] as PackedVector3Array).is_empty():
				stuck_no_route += 1
		print("t=%2d s: within 20 m %d; in WastelandNV %d; queue %d; routes %d (not found %d); door sequences %d (empty %d); waiting forever on a failed route %d" % [
			elapsed / 1000, near, in_wasteland, NpcSimulationServer.worker.get_pending_count(), counts["routes"], counts["routes_failed"],
			counts["sequences"], counts["sequences_empty"], stuck_no_route])
	NpcSimulationServer.package_runner.set_script_package_for_all(null)
	get_tree().quit()
