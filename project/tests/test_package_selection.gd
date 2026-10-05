extends Node

## Package selection (PackageRunner): Doc Mitchell's PKID, searched top to
## bottom by schedule and conditions, follows VCG01's stage (census A3); a
## script package wins over his own; EvaluatePackage chooses again at once.

const QUEST_EDITOR_ID := "VCG01"
## VCG01 stage -> the package Doc chooses there (census A3).
const EXPECTED := [
	[0, "VCG01DocMitchellFirstPosition"],
	[40, "VCG01DocMitchellBedsideStandingPackage"],
	[55, "VCG01DocMitchellTravelToPlayerAtTester"],
	[76, "VCG01DocMitchellTravelToSkullTestSpot"],
	[80, "VCG01DocMitchellTravelToExamSpot"],
	[110, "VCG01DocMitchellTravelToExit"],
	[115, "VCG01DocMitchellFarewellDialogueStart"],
]
const COMPLETED_PACKAGE := "VCG01DocMitchellSandbox"
const SCRIPT_PACKAGE := "DefaultFollowPlayerClose"

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
	var runner := NpcSimulationServer.package_runner
	var doc := EsmServer.find_reference_by_editor_id("DocMitchellREF") as ActorReference
	var quest := EsmServer.find_base_by_editor_id(QUEST_EDITOR_ID)
	ScriptServer.player_reference = EsmServer.get_player_reference()

	for row in EXPECTED:
		var stage: int = row[0]
		if stage > 0:
			_set_stage_quietly(quest, stage)
		var chosen := runner.choose_package(doc)
		check(_name(chosen) == row[1], "VCG01 stage %d: Doc chooses %s (%s)" % [stage, row[1], _name(chosen)])

	ScriptServer.run_debug_line("DocMitchellREF.evp")
	await get_tree().physics_frame
	await get_tree().physics_frame
	check(_name(doc.active_package) == EXPECTED[-1][1], "evp makes Doc run his chosen package at once (%s)" % _name(doc.active_package))

	var follow := EsmServer.find_base_by_editor_id(SCRIPT_PACKAGE) as PackageBase
	runner.set_script_package(doc, follow)
	await get_tree().physics_frame
	await get_tree().physics_frame
	check(doc.active_package == follow, "a script package wins over his own (%s)" % _name(doc.active_package))
	runner.set_script_package(doc, null)
	await get_tree().physics_frame
	await get_tree().physics_frame
	check(_name(doc.active_package) == EXPECTED[-1][1], "removing it returns him to his own (%s)" % _name(doc.active_package))

	QuestServer.complete_quest(quest)
	check(_name(runner.choose_package(doc)) == COMPLETED_PACKAGE, "VCG01 completed: Doc chooses %s (%s)" % [COMPLETED_PACKAGE, _name(runner.choose_package(doc))])

	var timed := PackageBase.new()
	timed.schedule_time = 22
	timed.schedule_duration_hours = 4
	check(PackageRunner.is_scheduled(timed, 23.5) and PackageRunner.is_scheduled(timed, 1.0) and not PackageRunner.is_scheduled(timed, 2.0) and not PackageRunner.is_scheduled(timed, 21.0), "a package from 22:00 for 4 hours runs at 23:30 and 01:00, not 02:00 or 21:00")
	check(not PackageRunner.is_scheduled(timed, -1.0) and PackageRunner.is_scheduled(PackageBase.new(), -1.0), "with no game clock only packages without an hour run")

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
