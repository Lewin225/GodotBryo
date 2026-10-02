extends Node

## Doc Mitchell's opening, headless: VCG01 from stage 0 to stage 55 driven only
## by its own quest script timers, Doc's SayTo lines and their end scripts,
## with time stepped by hand.

const STEP := 0.1
const LIMIT_SECONDS := 600.0
## The stage at the end of each step, in order (VCG01's stage and INFO
## scripts). 36 shows the race menu, whose MenuMode 1036 block sets 40 in the
## same step; 17, the unused sex choice, is never set.
const EXPECTED_STAGES := [0, 1, 3, 5, 7, 8, 10, 15, 25, 30, 35, 40, 45, 50, 55]

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
	var dialogue = get_node("/root/DialogueServer")
	var script_server = get_node("/root/ScriptServer")
	script_server.player_reference = esm_server.get_player_reference()
	var vcg01: QuestBase = esm_server.find_quest_by_editor_id("VCG01")
	var doc: EsmReference = esm_server.find_reference_by_editor_id("DocMitchellREF")
	var intro: DialogueTopicBase = esm_server.find_base_by_editor_id("VCG01Intro")

	var lines: Array[DialogueInfoBase] = []
	var subtitles: Array[String] = []
	dialogue.response_started.connect(func(line: DialogueLine, text: String) -> void:
		if lines.is_empty() or lines.back() != line.info:
			lines.append(line.info)
		subtitles.append(text))

	dialogue.reset()
	quests.stop_quest(vcg01)
	quests.reset_quest(vcg01)
	quests.set_stage(vcg01, 0)
	check(quests.is_running(vcg01), "SetStage VCG01 0 (VCG00's hand-over) starts VCG01")
	var stages: Array[int] = [0]
	var seconds := 0.0
	while seconds < LIMIT_SECONDS and quests.get_stage(vcg01) != 55:
		script_server._process(STEP)
		quests._process(STEP)
		dialogue._process(STEP)
		seconds += STEP
		if quests.get_stage(vcg01) != stages.back():
			stages.append(quests.get_stage(vcg01))

	check(quests.get_stage(vcg01) == 55, "VCG01 reaches stage 55 in %.1f s of game time" % seconds)
	check(stages == EXPECTED_STAGES, "through stages %s" % [stages])
	check(quests.is_stage_done(vcg01, 36) and not quests.is_stage_done(vcg01, 17),
			"stage 36's ShowRaceMenu ran the MenuMode 1036 block that sets 40; 17 was never set")
	var expected_lines: Array[DialogueInfoBase] = []
	for info in intro.infos:
		if info.form_id == 0x001074A2:
			break
		expected_lines.append(info)
	check(lines == expected_lines, "Doc says VCG01Intro's first %d lines in order (%d said)" % [expected_lines.size(), lines.size()])
	check(not subtitles.is_empty() and subtitles[0].begins_with("You're awake"), "the first subtitle is \"%s\"" % (subtitles[0] if not subtitles.is_empty() else ""))

	# A SayToDone block runs for the topic it names and no other.
	var source := "scn SayToDoneProbe\nshort heard\nbegin SayToDone VCG01Intro\nset heard to 1\nend\n"
	var probe := ScriptInterpreter.new(ScriptParser.new(ScriptLexer.new(source).tokenize()).parse(), script_server.function_registry)
	var instance := ScriptInstance.new()
	probe.run_block("SayToDone", ScriptExecutionContext.new(doc, instance), esm_server.find_base_by_editor_id("VCG01DocReactions"))
	var other_topic: Variant = instance.get_local("heard")
	probe.run_block("SayToDone", ScriptExecutionContext.new(doc, instance), intro)
	check(other_topic != 1 and instance.get_local("heard") == 1, "Begin SayToDone VCG01Intro runs for VCG01Intro only")

	var path: String = dialogue.voice_path(intro.infos[0], 0, doc)
	check(path == "sound\\voice\\falloutnv.esm\\maleuniquedocmitchell\\vcg01_vcg01intro_00104bee_1.ogg", "a line's voice file is %s" % path)
	var duration: float = dialogue.response_duration(intro.infos[0], 0, doc)
	check(duration > 0.5 and duration < 10.0, "and its length times the line (%.2f s)" % duration)

	quests.stop_quest(vcg01)
	quests.reset_quest(vcg01)
	dialogue.reset()
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
