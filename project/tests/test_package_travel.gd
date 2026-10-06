extends Node

## Travel packages (PackageRunner): with VCG01 at each stage, Doc Mitchell's
## chosen Travel package (census A3) takes him off screen (LowLevelTravel) to
## its Location 1 and completes; at stage 80 its radius-0 destination is his
## chair, which he then uses. A package replacing it gets him up.

const QUEST_EDITOR_ID := "VCG01"
## VCG01 stage -> where Doc's Travel package sends him.
const LEGS := [
	[40, "GSDocMitchellBesideMarker"],
	[55, "VCG01DocMarkerFaceTesterREF"],
	[76, "VCG01DocSkullTestMarkerREF"],
	[80, "DocMitchellChairREF"],
]
const SPEED_SCALE := 10.0
const LEG_FRAMES := 30 * 60
## How far from a marker Doc may stop, metres: the route ends where the
## navmesh does.
const TOLERANCE := 1.5

var failures := 0

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
	ScriptServer.player_reference = EsmServer.get_player_reference()
	var runner := NpcSimulationServer.package_runner
	var doc := EsmServer.find_reference_by_editor_id("DocMitchellREF") as ActorReference
	var quest := EsmServer.find_base_by_editor_id(QUEST_EDITOR_ID)

	for leg in LEGS:
		_set_stage_quietly(quest, leg[0])
		runner.evaluate_now(doc)
		var marker := EsmServer.find_reference_by_editor_id(leg[1])
		var frames := 0
		while frames < LEG_FRAMES and not doc.package_completed:
			await get_tree().physics_frame
			frames += 1
		var gap := doc.position.distance_to(marker.position) if doc.current_space_form_id == marker.current_space_form_id else INF
		check(doc.package_completed and gap <= TOLERANCE, "stage %d: %s takes Doc to %s and completes (%.2f m away, %.1f s)" % [leg[0], _name(doc.active_package), leg[1], gap, frames / 60.0])

	var chair := EsmServer.find_reference_by_editor_id("DocMitchellChairREF")
	check(doc.using == chair, "at stage 80 Doc uses his chair (%s)" % (doc.using.instance_id if doc.using != null else "nothing"))
	var reply: Dictionary = ScriptServer.run_debug_line("DocMitchellREF.IsCurrentFurnitureRef DocMitchellChairREF")
	check(int(reply.get("result", 0)) == 1, "DocMitchellREF.IsCurrentFurnitureRef DocMitchellChairREF is 1 (%s)" % reply.get("result"))

	_set_stage_quietly(quest, 110)
	runner.evaluate_now(doc)
	reply = ScriptServer.run_debug_line("DocMitchellREF.IsCurrentFurnitureRef DocMitchellChairREF")
	check(int(reply.get("result", 1)) == 0, "and 0 once he is up (%s)" % reply.get("result"))
	check(doc.using == null and _name(doc.active_package) == "VCG01DocMitchellTravelToExit" and not doc.package_completed, "at stage 110 his next package gets him up (%s, using %s)" % [_name(doc.active_package), doc.using])

	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

## Sets the stage without its result scripts: selection reads only the stage.
func _set_stage_quietly(quest: EsmBase, stage: int) -> void:
	var state := QuestServer.get_quest_state(quest)
	QuestServer.start_quest(quest)
	state.stage = stage
	state.stages_done[stage] = true

func _name(package: PackageBase) -> String:
	return package.editor_id if package != null else "none"
