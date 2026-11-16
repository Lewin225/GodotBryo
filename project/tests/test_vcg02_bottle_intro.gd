extends Node

## VCG02's bottle introduction. VCG02SunnyPatrolTriggerREF's OnTrigger
## SunnyREF block says VCG02SunnyBark to the player every physics frame while
## both are in it and objective 10 is not displayed; the bottle INFO
## (0010A1E6)'s begin script displays objective 10. The begin script runs when
## the line is said, before its voice has loaded, so the next frame's
## OnTrigger says nothing more: Sunny says the bottle line, not the topic's
## next Say Once INFO ("Okay, you're on", 0010A1E7, which sets stage 45).

const BOTTLE_INFO := 0x0010A1E6
const GECKO_INFO := 0x0010A1E7
const FRAMES := 30

var failures := 0


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var vcg02: QuestBase = EsmServer.find_quest_by_editor_id("VCG02")
	var sunny: EsmReference = EsmServer.find_reference_by_editor_id("SunnyREF")
	var trigger: EsmReference = EsmServer.find_reference_by_editor_id("VCG02SunnyPatrolTriggerREF")
	var player: EsmReference = EsmServer.get_player_reference()
	ScriptServer.player_reference = player
	var gecko_info := EsmServer.get_base(GECKO_INFO) as DialogueInfoBase
	QuestServer.start_quest(vcg02)
	QuestServer.set_stage(vcg02, 10)
	var ammo_before := int(ScriptServer.run_result_script("player.GetItemCount Ammo556mm", player))

	var said: Array[int] = []
	DialogueServer.line_finished.connect(func(line: DialogueLine) -> void: said.append(line.info.form_id))
	DialogueServer.response_started.connect(func(line: DialogueLine, _text: String) -> void:
		if not said.has(line.info.form_id):
			said.append(line.info.form_id))
	ScriptServer.dispatch_event(trigger, "OnTriggerEnter", player)
	ScriptServer.dispatch_event(trigger, "OnTrigger", sunny)
	check(QuestServer.is_objective_displayed(vcg02, 10), "objective 10 is displayed as soon as Sunny is told to say the bark")
	for frame in FRAMES:
		await get_tree().physics_frame
		ScriptServer.dispatch_event(trigger, "OnTrigger", sunny)

	var line := DialogueServer.get_line(sunny)
	check(line != null and line.info.form_id == BOTTLE_INFO, "after %d frames Sunny is saying the bottle line (%s)" % [FRAMES, "%08X" % line.info.form_id if line != null else "none"])
	check(not DialogueServer.has_said(gecko_info, sunny), "and has not said \"Okay, you're on\" (0010A1E7)")
	check(QuestServer.get_stage(vcg02) == 20, "VCG02 is at stage 20 (%d)" % QuestServer.get_stage(vcg02))
	check(not QuestServer.is_stage_done(vcg02, 45), "stage 45 (hunting geckos) is not done")
	var ammo_given := int(ScriptServer.run_result_script("player.GetItemCount Ammo556mm", player)) - ammo_before
	check(ammo_given == 30, "the begin script ran once: 30 rounds of 5.56mm given (%d)" % ammo_given)
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
