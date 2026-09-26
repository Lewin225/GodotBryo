extends Node

## QuestServer against the shipped quests: canonical states, starting quests,
## quest scripts on their delay, stages and their result scripts.

var failures := 0

func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1

func _ready() -> void:
	var esm_server = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var quests = get_node("/root/QuestServer")
	var script_server = get_node("/root/ScriptServer")
	await get_tree().process_frame

	# One canonical QuestState per QUST.
	var repcon: EsmBase = esm_server.find_quest_by_editor_id("RepconHQFreeform")
	var state: QuestState = quests.get_quest_state(repcon)
	check(state != null and state.quest == repcon and quests.get_quest_state(repcon) == state and state.stage == 0,
			"a quest has one canonical QuestState, starting at stage 0")
	check(quests.get_quest_state(esm_server.get_base(0x000E3778)) == null, "a non-quest record has no QuestState")
	check(script_server.get_quest_instance(repcon) == state.script_instance and state.script_instance != null,
			"the quest's script variables live on its QuestState")

	# Starting a new game starts the start-enabled quests.
	quests.begin_game()
	var running := 0
	for row: Dictionary in esm_server.get_record_index():
		if String(row.get("record_type", "")) == "QUST" and quests.is_running(esm_server.get_base(int(row["form_id"]))):
			running += 1
	check(running == 281, "begin_game starts the 281 start-enabled quests (%d)" % running)

	# A running quest's script runs once its delay has passed: Generic's GameMode
	# opens with `Set Addicted to 0`.
	var generic: EsmBase = esm_server.find_quest_by_editor_id("Generic")
	var generic_vars: ScriptInstance = script_server.get_quest_instance(generic)
	var delay: float = quests.get_script_delay(generic)
	check(delay > 0.0, "Generic has a script delay (%.2f s)" % delay)
	generic_vars.set_local("Addicted", 99)
	quests._elapsed[generic.form_id] = 0.0
	quests._process(delay * 0.5)
	check(generic_vars.get_local("Addicted") == 99, "the quest script does not run before its delay")
	quests._process(delay * 0.6)
	check(generic_vars.get_local("Addicted") != 99, "it runs once the delay has passed")
	quests.stop_quest(generic)
	generic_vars.set_local("Addicted", 99)
	quests._process(delay * 2.0)
	check(not quests.is_running(generic) and generic_vars.get_local("Addicted") == 99, "a stopped quest's script does not run")

	# Stages run their result scripts: VCG01 75 -> SetStage 76 -> SetStage 79.
	var vcg01: EsmBase = esm_server.find_quest_by_editor_id("VCG01")
	script_server.run_debug_line("SetStage VCG01 75")
	check(quests.is_stage_done(vcg01, 75) and quests.is_stage_done(vcg01, 76) and quests.is_stage_done(vcg01, 79),
			"setting a stage runs its result script, which can set further stages (75, 76, 79 done)")
	check(script_server.run_debug_line("GetStageDone VCG01 76").get("result") == 1, "GetStageDone reads it from scripts")

	# Script control of quests.
	script_server.run_debug_line("StartQuest RepconHQFreeform")
	check(quests.is_running(repcon) and script_server.run_debug_line("GetQuestRunning RepconHQFreeform").get("result") == 1, "StartQuest / GetQuestRunning")
	script_server.run_debug_line("SetQuestDelay RepconHQFreeform 0.5")
	check(is_equal_approx(quests.get_script_delay(repcon), 0.5), "SetQuestDelay sets the quest's script delay")
	script_server.run_debug_line("StopQuest RepconHQFreeform")
	check(not quests.is_running(repcon), "StopQuest")

	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
