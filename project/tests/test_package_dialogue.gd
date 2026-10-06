extends Node

## Dialogue packages (PackageRunner): Doc Mitchell's farewell at VCG01 stage
## 115 (wait at the exit marker, no trigger location, the player within 420
## units) and Sunny Smiles' meeting (wait at her editor location until the
## player is inside SunnySmilesTrigger, then the player within 256 units) each
## end in a conversation with the player, off screen (LowLevelTravel).

const SPEED_SCALE := 10.0
const FRAMES := 30 * 60
## Frames Sunny is given to not greet while the player is outside her trigger.
const WAIT_FRAMES := 5 * 60

var failures := 0
var started := []

func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	NpcSimulationServer.records_per_frame = 512
	NpcSimulationServer.seed()
	if not NpcSimulationServer.is_seeded:
		await NpcSimulationServer.seed_finished
	NpcSimulationServer.low_level_travel.speed_scale = SPEED_SCALE
	var player := EsmServer.get_player_reference()
	ScriptServer.player_reference = player
	DialogueServer.conversation_started.connect(func(speaker: EsmReference, listener: EsmReference) -> void: started.append([speaker, listener]))
	await _check_doc(player)
	await _check_sunny(player)
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

func _check_doc(player: ActorReference) -> void:
	var doc := EsmServer.find_reference_by_editor_id("DocMitchellREF") as ActorReference
	var quest := EsmServer.find_base_by_editor_id("VCG01")
	var state := QuestServer.get_quest_state(quest)
	QuestServer.start_quest(quest)
	state.stage = 115
	state.stages_done[115] = true
	var exit_marker := EsmServer.get_reference("authored:00105BCF")
	_move(player, exit_marker.current_space_form_id, exit_marker.position + Vector3(2.0, 0.0, 0.0))
	NpcSimulationServer.package_runner.evaluate_now(doc)
	check(doc.active_package != null and doc.active_package.editor_id == "VCG01DocMitchellFarewellDialogueStart", "at stage 115 Doc runs his farewell (%s)" % _name(doc.active_package))
	started.clear()
	var frames := await _wait_for_conversation(doc)
	check(_started_with(doc, player), "Doc goes to the exit and force-greets the player (%.1f s, %.2f m apart)" % [frames / 60.0, doc.position.distance_to(player.position)])
	check(doc.package_completed, "and the package completes")
	DialogueServer.end_conversation(false)

func _check_sunny(player: ActorReference) -> void:
	var sunny := EsmServer.find_reference_by_editor_id("SunnyRef") as ActorReference
	# Her GREETING lines belong to VFreeformGoodsprings, running in a real game.
	QuestServer.start_quest(EsmServer.find_base_by_editor_id("VFreeformGoodsprings"))
	var package := EsmServer.find_base_by_editor_id("SunnyMeetPlayerDialoguePackage") as PackageBase
	var trigger := package.get_location_reference(2)
	check(PackageRunner.is_inside_primitive(trigger, trigger.position) and not PackageRunner.is_inside_primitive(trigger, trigger.position + Vector3(50.0, 0.0, 0.0)), "SunnySmilesTrigger's volume holds its own centre and not a point 50 m off")
	var outside := _point_outside(trigger, sunny)
	_move(player, sunny.current_space_form_id, outside)
	NpcSimulationServer.package_runner.evaluate_now(sunny)
	check(sunny.active_package == package, "Sunny runs SunnyMeetPlayerDialoguePackage (%s)" % _name(sunny.active_package))
	started.clear()
	for frame in WAIT_FRAMES:
		await get_tree().physics_frame
	check(started.is_empty(), "with the player outside her trigger she waits")
	_move(player, trigger.current_space_form_id, trigger.position)
	var frames := await _wait_for_conversation(sunny)
	check(_started_with(sunny, player), "once the player is inside it she comes over and greets (%.1f s, %.2f m apart)" % [frames / 60.0, sunny.position.distance_to(player.position)])
	DialogueServer.end_conversation(false)

## A point in the saloon outside the trigger: Sunny's own position when she is
## outside it, else the trigger's centre moved 20 m.
func _point_outside(trigger: EsmReference, sunny: ActorReference) -> Vector3:
	if not PackageRunner.is_inside_primitive(trigger, sunny.position):
		return sunny.position
	return trigger.position + Vector3(20.0, 0.0, 0.0)

func _wait_for_conversation(speaker: ActorReference) -> int:
	var frames := 0
	while frames < FRAMES and not _started_by(speaker):
		await get_tree().physics_frame
		frames += 1
	return frames

func _started_by(speaker: EsmReference) -> bool:
	for pair in started:
		if pair[0] == speaker:
			return true
	return false

func _started_with(speaker: EsmReference, listener: EsmReference) -> bool:
	for pair in started:
		if pair[0] == speaker and pair[1] == listener:
			return true
	return false

func _move(reference: EsmReference, space: int, position: Vector3) -> void:
	ScriptServer.move_reference(reference, space, position, Vector3.ZERO)
	ScriptServer.apply_pending_moves()

func _name(package: PackageBase) -> String:
	return package.editor_id if package != null else "none"
