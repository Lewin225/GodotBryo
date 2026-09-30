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

	# A stage whose unconditioned log entry is flagged complete-quest completes it.
	var completing_quest: QuestBase = null
	var completing_stage := -1
	for row: Dictionary in esm_server.get_record_index():
		if String(row.get("record_type", "")) != "QUST":
			continue
		var candidate := esm_server.get_base(int(row["form_id"])) as QuestBase
		for stage: QuestStage in candidate.stages:
			for entry: QuestLogEntry in stage.log_entries:
				if entry.conditions.is_empty() and (entry.flags & QuestLogEntry.FLAG_COMPLETE_QUEST) != 0 and entry.script_source.strip_edges().is_empty():
					completing_quest = candidate
					completing_stage = stage.index
					break
			if completing_quest != null:
				break
		if completing_quest != null:
			break
	check(completing_quest != null, "found a quest stage that completes its quest")
	if completing_quest != null:
		var edid := completing_quest.editor_id
		check(script_server.run_debug_line("GetQuestCompleted %s" % edid).get("result") == 0, "GetQuestCompleted is 0 before (%s)" % edid)
		script_server.run_debug_line("SetStage %s %d" % [edid, completing_stage])
		check(quests.is_completed(completing_quest) and script_server.run_debug_line("GetQuestCompleted %s" % edid).get("result") == 1,
				"setting a completing stage makes GetQuestCompleted 1 (%s %d)" % [edid, completing_stage])

	# Script control of quests.
	script_server.run_debug_line("StartQuest RepconHQFreeform")
	check(quests.is_running(repcon) and script_server.run_debug_line("GetQuestRunning RepconHQFreeform").get("result") == 1, "StartQuest / GetQuestRunning")
	script_server.run_debug_line("SetQuestDelay RepconHQFreeform 0.5")
	check(is_equal_approx(quests.get_script_delay(repcon), 0.5), "SetQuestDelay sets the quest's script delay")
	script_server.run_debug_line("StopQuest RepconHQFreeform")
	check(not quests.is_running(repcon), "StopQuest")

	_check_objectives(esm_server, quests, script_server)
	_check_quest_state_functions(esm_server, quests, script_server)
	_check_stage_entries(esm_server, quests, script_server)

	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

## Objective state on VMQ01, which defines objectives 10, 20, 25, 30, 34, 36,
## 38, 40, 45, 46, 50 and 60 (not 15, which one shipped INFO completes).
## CompleteQuest, FailQuest, CompleteAllObjectives, ResetQuest, SetActiveQuest
## and SetQuestObject, on quests and items shipped scripts call them on.
func _check_quest_state_functions(esm_server, quests, script_server) -> void:
	var vms03: QuestBase = esm_server.find_quest_by_editor_id("VMS03")
	var was_running: bool = quests.is_running(vms03)
	script_server.run_debug_line("CompleteQuest VMS03")
	check(quests.is_completed(vms03) and quests.is_running(vms03) == was_running, "CompleteQuest completes the quest and leaves whether it runs alone")
	var pimp: QuestBase = esm_server.find_quest_by_editor_id("VFSAtomicPimp")
	script_server.run_debug_line("FailQuest VFSAtomicPimp")
	check(quests.get_quest_state(pimp).failed, "FailQuest fails the quest")

	var vms20: QuestBase = esm_server.find_quest_by_editor_id("VMS20")
	check(vms20 != null and not vms20.objectives.is_empty(), "VMS20 has objectives (%d)" % (vms20.objectives.size() if vms20 != null else 0))
	var first_index: int = vms20.objectives[0].index
	quests.set_objective_displayed(vms20, first_index, true)
	script_server.run_debug_line("CompleteAllObjectives VMS20")
	var all_completed := true
	for objective in vms20.objectives:
		all_completed = all_completed and quests.is_objective_completed(vms20, objective.index)
	check(all_completed, "CompleteAllObjectives completes every objective VMS20 defines")
	var displayed_count: int = quests.get_quest_state(vms20).objectives_displayed.size()
	check(displayed_count == 1, "and changes no objective's displayed state (%d displayed)" % displayed_count)

	var radio: QuestBase = esm_server.find_quest_by_editor_id("VEFR01NCRGood2EmergencyRadio")
	var radio_state: QuestState = quests.get_quest_state(radio)
	quests.start_quest(radio)
	quests.set_stage(radio, 10)
	radio_state.completed = true
	if not radio.objectives.is_empty():
		quests.set_objective_displayed(radio, radio.objectives[0].index, true)
	script_server.run_debug_line("ResetQuest VEFR01NCRGood2EmergencyRadio")
	check(radio_state.stage == 0 and radio_state.stages_done.is_empty() and radio_state.objectives_displayed.is_empty()
			and not radio_state.completed and radio_state.running, "ResetQuest clears stages, objectives and completion, and leaves it running")
	quests.stop_quest(radio)

	var changed := []
	quests.active_quest_changed.connect(func(quest): changed.append(quest))
	script_server.run_debug_line("SetActiveQuest VMS20")
	check(quests.active_quest == vms20 and changed == [vms20], "SetActiveQuest sets the active quest and signals it")
	quests.active_quest = null

	var vcg01: QuestBase = esm_server.find_quest_by_editor_id("VCG01")
	check(vcg01.full_name == "Ain't That a Kick in the Head", "VCG01 is Ain't That a Kick in the Head (%s)" % vcg01.full_name)
	var granted := []
	quests.quest_granted.connect(func(quest): granted.append(quest))
	var first: int = vcg01.objectives[0].index
	var second: int = vcg01.objectives[1].index
	quests.set_objective_displayed(vcg01, first, true)
	quests.set_objective_displayed(vcg01, second, true)
	check(granted == [vcg01], "displaying a quest's first objective grants it, once")
	quests.set_objective_displayed(vcg01, first, false)
	quests.set_objective_displayed(vcg01, second, false)

	var rifle: EsmBase = esm_server.find_base_by_editor_id("VFSWeapLaserRifleVanGraff")
	check(rifle is WeaponBase and (rifle.record_flags & EsmBase.RECORD_FLAG_QUEST_ITEM) != 0 and quests.is_quest_object(rifle),
			"VFSWeapLaserRifleVanGraff is authored as a quest item (record flag 0x400)")
	script_server.run_debug_line("SetQuestObject VFSWeapLaserRifleVanGraff 0")
	check(not quests.is_quest_object(rifle), "SetQuestObject 0 makes it an ordinary item")
	script_server.run_debug_line("SetQuestObject VFSWeapLaserRifleVanGraff 1")
	check(quests.is_quest_object(rifle), "SetQuestObject 1 makes it a quest item again")
	check(not quests.is_quest_object(esm_server.find_base_by_editor_id("WeapNV9mmPistol")), "an unflagged weapon is not a quest item")

## SetStage runs the first log entry whose conditions pass. VMQTops stage 20's
## two entries test its script variable 0x11 == 0 and == 1; CGTutorial stage
## 212's test IsWin32 == 1 (the PC entry) and == 0.
func _check_stage_entries(esm_server, quests, script_server) -> void:
	var tops: QuestBase = esm_server.find_quest_by_editor_id("VMQTops")
	var entries: Array[QuestLogEntry] = tops.get_stage(20).log_entries
	var variable: String = script_server.script_variable_name(tops.script_form_id, 0x11)
	script_server.get_quest_instance(tops).set_local(variable, 0)
	check(quests.set_stage(tops, 20) == entries[0], "VMQTops stage 20 runs its first entry while %s is 0" % variable)
	quests.reset_quest(tops)
	script_server.get_quest_instance(tops).set_local(variable, 1)
	check(quests.set_stage(tops, 20) == entries[1], "and its second once it is 1")
	quests.reset_quest(tops)
	script_server.get_quest_instance(tops).set_local(variable, 2)
	check(quests.set_stage(tops, 20) == null and quests.get_stage(tops) == 20, "neither passes at 2: no entry runs, the stage is still set")
	quests.reset_quest(tops)

	# A stage already done does nothing again unless the quest allows repeated
	# stages: VMQTops does not; a quest that does runs a stage again.
	script_server.get_quest_instance(tops).set_local(variable, 0)
	quests.set_stage(tops, 20)
	quests.set_stage(tops, 30)
	check(not tops.allows_repeated_stages and quests.set_stage(tops, 20) == null and quests.get_stage(tops) == 30,
			"VMQTops does not allow repeated stages: SetStage 20 again runs nothing and leaves stage 30")
	quests.reset_quest(tops)
	var repeating: QuestBase = null
	for row: Dictionary in esm_server.get_record_index():
		if String(row.get("record_type", "")) != "QUST":
			continue
		var candidate: QuestBase = esm_server.get_base(int(row["form_id"]))
		for stage in candidate.stages:
			if candidate.allows_repeated_stages and repeating == null and not stage.log_entries.is_empty() and stage.log_entries[0].conditions.is_empty() and stage.log_entries[0].script_source.strip_edges().is_empty():
				repeating = candidate
	if repeating != null:
		var repeat_stage: int = -1
		for stage in repeating.stages:
			if repeat_stage < 0 and not stage.log_entries.is_empty() and stage.log_entries[0].conditions.is_empty() and stage.log_entries[0].script_source.strip_edges().is_empty():
				repeat_stage = stage.index
		quests.set_stage(repeating, repeat_stage)
		check(quests.set_stage(repeating, repeat_stage) == repeating.get_stage(repeat_stage).log_entries[0],
				"%s allows repeated stages: SetStage %d runs again" % [repeating.editor_id, repeat_stage])
		quests.reset_quest(repeating)
	else:
		check(false, "a quest allowing repeated stages has a stage with an unconditioned, scriptless entry")
	var tutorial: QuestBase = esm_server.find_quest_by_editor_id("CGTutorial")
	check(quests.set_stage(tutorial, 212) == tutorial.get_stage(212).log_entries[0], "CGTutorial stage 212 runs its PC entry")
	quests.reset_quest(tutorial)

func _check_objectives(esm_server, quests, script_server) -> void:
	var vmq01: QuestBase = esm_server.find_quest_by_editor_id("VMQ01")
	var state: QuestState = quests.get_quest_state(vmq01)
	check(not quests.is_objective_displayed(vmq01, 10) and not quests.is_objective_completed(vmq01, 10)
			and script_server.run_debug_line("GetObjectiveDisplayed VMQ01 10").get("result") == 0,
			"an objective starts neither displayed nor completed")

	# QuestServer methods.
	check(quests.set_objective_displayed(vmq01, 20, true) and state.objectives_displayed == {20: true},
			"set_objective_displayed records the index on the QuestState")
	check(quests.set_objective_completed(vmq01, 20, true) and quests.is_objective_displayed(vmq01, 20)
			and state.objectives_completed == {20: true}, "set_objective_completed records it and leaves it displayed")
	check(quests.set_objective_displayed(vmq01, 20, false) and not quests.is_objective_displayed(vmq01, 20)
			and quests.is_objective_completed(vmq01, 20), "clearing displayed leaves it completed")
	quests.set_objective_completed(vmq01, 20, false)
	check(state.objectives_displayed.is_empty() and state.objectives_completed.is_empty(), "clearing both leaves no state")

	# Script functions.
	script_server.run_debug_line("SetObjectiveDisplayed VMQ01 10 1")
	check(script_server.run_debug_line("GetObjectiveDisplayed VMQ01 10").get("result") == 1
			and script_server.run_debug_line("GetObjectiveCompleted VMQ01 10").get("result") == 0,
			"SetObjectiveDisplayed VMQ01 10 1 displays objective 10 only")
	var line := "if GetObjectiveDisplayed VMQ01 10 == 1 && GetObjectiveCompleted VMQ01 10 == 0\nSetObjectiveCompleted VMQ01 10 1\nendif"
	script_server.run_debug_line(line)
	check(quests.is_objective_completed(vmq01, 10) and script_server.run_debug_line("GetObjectiveCompleted VMQ01 10").get("result") == 1,
			"the getters take two arguments inside an expression, and SetObjectiveCompleted completes it")
	check(script_server.run_debug_line("GetObjectiveDisplayed VMQ01 10").get("result") == 1, "completing leaves it displayed")
	script_server.run_debug_line("SetObjectiveDisplayed VMQ01 10 0")
	script_server.run_debug_line("SetObjectiveCompleted VMQ01 10 0")
	check(not quests.is_objective_displayed(vmq01, 10) and not quests.is_objective_completed(vmq01, 10), "flag 0 clears both")
	script_server.run_debug_line("SetObjectiveDisplayed VMQ01 50 2")
	check(quests.is_objective_displayed(vmq01, 50), "a nonzero flag other than 1 sets (VMQHouse4 50 2 is shipped)")
	script_server.run_debug_line("SetObjectiveCompleted VMQ01 50")
	check(not quests.is_objective_completed(vmq01, 50)
			and script_server.run_debug_line("SetObjectiveCompleted VMQ01 50").get("result") == 0,
			"without a flag nothing changes")

	# An index the quest does not define.
	check(not quests.set_objective_completed(vmq01, 15, true) and not state.objectives_completed.has(15),
			"an undefined objective index is refused and not recorded")
	check(script_server.run_debug_line("SetObjectiveDisplayed VMQ01 15 1").get("result") == 0
			and script_server.run_debug_line("GetObjectiveDisplayed VMQ01 15").get("result") == 0
			and not state.objectives_displayed.has(15), "from scripts too: it reads 0 and cannot be set")
	check(script_server.run_debug_line("GetObjectiveDisplayed NoSuchQuest 10").get("result") == 0,
			"an unknown quest reads 0")

	# The state survives a save.
	quests.set_objective_completed(vmq01, 60, true)
	var path := "user://test_quest_state_objectives.tres"
	var saved := ResourceSaver.save(state, path)
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as QuestState
	check(saved == OK and loaded != null and loaded.objectives_displayed == {50: true} and loaded.objectives_completed == {60: true},
			"objective state saves and loads with the QuestState")
