extends Node

## Cycle rates with every placed actor running DefaultFollowPlayerClose and
## the player in GSDocMitchellHouse, sampled every 5 s for SECONDS: how long a
## full unleased sweep takes, the simulation thread's queue and how many jobs
## it finished, how many actors have a move_target, a pending or failed door
## plan, and how many have moved since the start.

const SECONDS := 60
## Off-screen travel speed multiplier (DebugSetLowLevelSpeed).
const SPEED := 10.0

var _jobs_finished := 0

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	NpcSimulationServer.records_per_frame = 512
	NpcSimulationServer.seed()
	if not NpcSimulationServer.is_seeded:
		await NpcSimulationServer.seed_finished
	var player := EsmServer.get_player_reference()
	ScriptServer.player_reference = player
	var house := EsmServer.find_form_id_by_editor_id("GSDocMitchellHouse")
	var doc := EsmServer.find_reference_by_editor_id("DocMitchellREF")
	ScriptServer.move_reference(player, house, doc.position + Vector3(2.0, 0.0, 0.0), Vector3.ZERO)
	ScriptServer.apply_pending_moves()
	NpcSimulationServer.route_ready.connect(func(_id: int, _r: Dictionary) -> void: _jobs_finished += 1)
	NpcSimulationServer.cross_space_route_ready.connect(func(_id: int, _r: Dictionary) -> void: _jobs_finished += 1)
	var runner := NpcSimulationServer.package_runner
	NpcSimulationServer.low_level_travel.speed_scale = SPEED
	var routes_failed := [0]
	NpcSimulationServer.route_ready.connect(func(_id: int, r: Dictionary) -> void:
		if not bool(r.get("found", false)):
			routes_failed[0] += 1)
	var actors: Array = NpcSimulationServer.actors_by_instance_id.values()
	var start_positions := {}
	for actor: ActorReference in actors:
		start_positions[actor] = [actor.current_space_form_id, actor.position]
	runner.set_package_for_all(EsmServer.find_base_by_editor_id("DefaultFollowPlayerClose") as PackageBase)
	var sweeps := 0
	var last_index := 0
	var sweep_started := Time.get_ticks_msec()
	var sweep_times := []
	var started := Time.get_ticks_msec()
	var next_report := 5000
	var last_finished := 0
	while Time.get_ticks_msec() - started < SECONDS * 1000:
		await get_tree().physics_frame
		if runner._sweep_index < last_index:
			sweeps += 1
			sweep_times.append(Time.get_ticks_msec() - sweep_started)
			sweep_started = Time.get_ticks_msec()
		last_index = runner._sweep_index
		var elapsed := Time.get_ticks_msec() - started
		if elapsed >= next_report:
			next_report += 10000
			var targets := 0
			var pending := 0
			var failed := 0
			var moved := 0
			var same_space := 0
			var waiting_route := 0
			var no_route := 0
			var walking_plan := 0
			var travel := NpcSimulationServer.low_level_travel
			for actor: ActorReference in actors:
				if actor.has_move_target:
					targets += 1
				var plan: Dictionary = runner._door_plans.get(actor, {})
				if not plan.is_empty():
					if plan["state"] == PackageRunner.PLAN_PENDING:
						pending += 1
					elif plan["state"] == PackageRunner.PLAN_FAILED:
						failed += 1
				var start: Array = start_positions[actor]
				if actor.current_space_form_id != start[0] or actor.position.distance_to(start[1]) > 0.5:
					moved += 1
				if actor.current_space_form_id == player.current_space_form_id:
					same_space += 1
				var route: Dictionary = travel._routes.get(actor, {})
				if actor.has_move_target and not route.is_empty():
					if route["request_id"] != -1 and travel._actors_by_request.has(route["request_id"]):
						waiting_route += 1
					elif (route["waypoints"] as PackedVector3Array).is_empty():
						no_route += 1
				if not plan.is_empty() and plan["state"] == PackageRunner.PLAN_READY:
					walking_plan += 1
			print("t=%2d s: queue %d; targets %d (waiting for a route %d, no route found %d); plans pending %d, walking %d, failed %d; leg routes not found %d; moved %d; in the player's space %d" % [
				elapsed / 1000, NpcSimulationServer.worker.get_pending_count(), targets, waiting_route, no_route,
				pending, walking_plan, failed, routes_failed[0], moved, same_space])
			last_finished = _jobs_finished
	runner.set_package_for_all(null)
	get_tree().quit()
