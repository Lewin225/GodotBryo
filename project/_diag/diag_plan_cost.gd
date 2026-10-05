extends Node

## What a cross-space plan costs, on 50 placed actors in other spaces than the
## player (in GSDocMitchellHouse): the full route_across_spaces (every leg's
## walking route, alternative door sequences until one is walkable), against
## the door sequence alone (find_component_paths) plus the first leg's walking
## route.

const SAMPLE := 50

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	NpcSimulationServer.records_per_frame = 512
	NpcSimulationServer.seed()
	if not NpcSimulationServer.is_seeded:
		await NpcSimulationServer.seed_finished
	var server := NpcSimulationServer
	var house := EsmServer.find_form_id_by_editor_id("GSDocMitchellHouse")
	var doc := EsmServer.find_reference_by_editor_id("DocMitchellREF")
	var to_position: Vector3 = doc.position + Vector3(2.0, 0.0, 0.0)
	var actors: Array = server.actors_by_instance_id.values()
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var full_ms := []
	var sequence_ms := []
	var first_leg_ms := []
	var doors := []
	var tried := 0
	while full_ms.size() < SAMPLE and tried < 2000:
		tried += 1
		var actor: ActorReference = actors[rng.randi_range(0, actors.size() - 1)]
		if actor.current_space_form_id == house or actor.current_space_form_id == 0:
			continue
		var started := Time.get_ticks_usec()
		var full: Dictionary = server.route_across_spaces(actor.current_space_form_id, actor.position, house, to_position)
		var full_us := Time.get_ticks_usec() - started
		if not bool(full.get("found", false)):
			continue
		full_ms.append(full_us / 1000.0)
		doors.append(int(full["door_count"]))
		started = Time.get_ticks_usec()
		var from_component: int = server.get_component_at(actor.current_space_form_id, actor.position, server.ground_snap_radius * 4.0)
		var to_component: int = server.get_component_at(house, to_position, server.ground_snap_radius * 4.0)
		var paths: Array = server.find_component_paths(from_component, to_component) if from_component >= 0 and to_component >= 0 else []
		sequence_ms.append((Time.get_ticks_usec() - started) / 1000.0)
		if paths.is_empty():
			first_leg_ms.append(0.0)
			continue
		var first_portal = paths[0][0]
		started = Time.get_ticks_usec()
		server.route(actor.current_space_form_id, actor.position, first_portal.source_position)
		first_leg_ms.append((Time.get_ticks_usec() - started) / 1000.0)
	print("%d actors (doors on their routes: %s)" % [full_ms.size(), _summary(doors)])
	print("full route_across_spaces: %s ms" % _summary(full_ms))
	print("door sequence only: %s ms" % _summary(sequence_ms))
	print("first leg's walking route: %s ms" % _summary(first_leg_ms))
	get_tree().quit()

func _summary(values: Array) -> String:
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0.0
	for value in sorted:
		total += float(value)
	return "mean %.2f, median %.2f, max %.2f" % [total / maxi(sorted.size(), 1), float(sorted[sorted.size() / 2]), float(sorted[sorted.size() - 1])]
