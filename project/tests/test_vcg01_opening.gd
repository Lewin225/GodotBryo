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
	var played_voice := [false]
	dialogue.response_started.connect(func(line: DialogueLine, text: String) -> void:
		if lines.is_empty() or lines.back() != line.info:
			lines.append(line.info)
		subtitles.append(text)
		if line.voice_player != null and line.voice_player.stream != null and line.voice_player.playing:
			played_voice[0] = true)

	dialogue.reset()
	quests.stop_quest(vcg01)
	quests.reset_quest(vcg01)
	quests.set_stage(vcg01, 0)
	check(quests.is_running(vcg01), "SetStage VCG01 0 (VCG00's hand-over) starts VCG01")
	var stages: Array[int] = [0]
	var seconds := 0.0
	while seconds < LIMIT_SECONDS and quests.get_stage(vcg01) != 55:
		_step(script_server, quests, dialogue)
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
	check(played_voice[0], "Doc's lines play their voice files")

	# A SayToDone block runs for the topic it names and no other.
	var source := "scn SayToDoneProbe\nshort heard\nbegin SayToDone VCG01Intro\nset heard to 1\nend\n"
	var probe := ScriptInterpreter.new(ScriptParser.new(ScriptLexer.new(source).tokenize()).parse(), script_server.function_registry)
	var instance := ScriptInstance.new()
	probe.run_block("SayToDone", ScriptExecutionContext.new(doc, instance), esm_server.find_base_by_editor_id("VCG01DocReactions"))
	var other_topic: Variant = instance.get_local("heard")
	probe.run_block("SayToDone", ScriptExecutionContext.new(doc, instance), intro)
	check(other_topic != 1 and instance.get_local("heard") == 1, "Begin SayToDone VCG01Intro runs for VCG01Intro only")

	# On to the vigor tester: entering its trigger sets 60; Doc's line there
	# displays objective 30; activating the tester sets 65, whose timer sets 70,
	# Doc's reaction, whose end script sets 75 (the shipped stages then carry on
	# to 79, skipping the cut skull test).
	var trigger: EsmReference = esm_server.get_reference("authored:00104C16")
	var tester: EsmReference = esm_server.get_reference("authored:00104C13")
	script_server.dispatch_event(trigger, "OnTriggerEnter", script_server.player_reference)
	check(quests.get_stage(vcg01) == 60, "entering the vigor tester's trigger sets stage 60 (%d)" % quests.get_stage(vcg01))
	var waited := 0.0
	while waited < 60.0 and not quests.is_objective_displayed(vcg01, 30):
		_step(script_server, quests, dialogue)
		waited += STEP
	check(quests.is_objective_displayed(vcg01, 30), "Doc's line at 60 displays objective 30 (after %.1f s)" % waited)
	# Luck 10 is the player's most extreme SPECIAL: VCG01SCRIPT's reaction block
	# (abs of each deviation from 5.5) picks nDocReaction 4, high luck.
	var player_ctx := ScriptExecutionContext.new(script_server.player_reference)
	script_server.function_registry.call_function("SetActorValue", ["Luck", 10], player_ctx)
	var reactions_said: Array[int] = []
	dialogue.response_started.connect(func(line: DialogueLine, _text: String) -> void:
		if line.topic != null and line.topic.editor_id == "VCG01DocReactions":
			reactions_said.append(line.info.form_id))
	script_server.activate(tester, script_server.player_reference)
	check(quests.get_stage(vcg01) == 65, "activating the vigor tester sets stage 65 (%d)" % quests.get_stage(vcg01))
	waited = 0.0
	while waited < 120.0 and quests.get_stage(vcg01) < 75:
		_step(script_server, quests, dialogue)
		waited += STEP
	check(quests.is_stage_done(vcg01, 70) and quests.is_stage_done(vcg01, 75), "65's timer sets 70, Doc reacts, and his line sets 75 (now %d)" % quests.get_stage(vcg01))
	var special: String = script_server.script_variable_name(vcg01.script_form_id, 5)
	check(script_server.get_quest_instance(vcg01).get_local(special) == 4 and reactions_said == [0x00104BE2],
			"with Luck 10, %s is 4 and Doc says 00104BE2, \"With luck like yours...\" (%s, %s)" % [special, script_server.get_quest_instance(vcg01).get_local(special), reactions_said])
	script_server.function_registry.call_function("SetActorValue", ["Luck", 5], player_ctx)

	# The Rorschach test, started from the console the way the couch trigger
	# starts it (it needs the player on the couch and Doc in his chair):
	# Doc's VCG01 GREETING offers VCG01DocMitchellTopic000-005; each choice
	# links onward, and the last sets stage 85.
	script_server.run_debug_line("set VCG01.bGiveTest to 1")
	var first_choices: Array = []
	var greeting_infos: Array[int] = []
	dialogue.choices_ready.connect(func(choices: Array[DialogueChoice]) -> void:
		if first_choices.is_empty():
			first_choices.append_array(choices))
	dialogue.response_started.connect(func(line: DialogueLine, _text: String) -> void:
		if line.topic != null and line.topic.editor_id == "GREETING" and not greeting_infos.has(line.info.form_id):
			greeting_infos.append(line.info.form_id))
	script_server.run_debug_line("DocMitchellREF.StartConversation Player")
	check(dialogue.get_conversation_speaker() == doc and script_server.get_menu() == script_server.MENU_DIALOG,
			"StartConversation Player opens a conversation with Doc, menu 1009 (Dialog)")
	var picks := 0
	waited = 0.0
	while waited < 300.0 and dialogue.get_conversation_speaker() != null:
		_step(script_server, quests, dialogue)
		waited += STEP
		if not dialogue.get_choices().is_empty():
			dialogue.choose(0)
			picks += 1
	var offered: Array[String] = []
	for choice: DialogueChoice in first_choices:
		offered.append(choice.topic.editor_id)
	check(greeting_infos == [0x0010558F], "Doc greets with 0010558F, the test's first prompt (%s)" % [greeting_infos])
	check(offered == ["VCG01DocMitchellTopic000", "VCG01DocMitchellTopic001", "VCG01DocMitchellTopic002", "VCG01DocMitchellTopic003", "VCG01DocMitchellTopic004", "VCG01DocMitchellTopic005"],
			"his line's Link To offers Topic000-005 (%s)" % [offered])
	check(quests.is_stage_done(vcg01, 85) and dialogue.get_conversation_speaker() == null and not script_server.is_menu_mode(),
			"%d choices later the test sets stage 85 and the Goodbye line ends the conversation" % picks)

	var path: String = dialogue.voice_path(intro.infos[0], 0, doc)
	check(path == "sound\\voice\\falloutnv.esm\\maleuniquedocmitchell\\vcg01_vcg01intro_00104bee_1.ogg", "a line's voice file is %s" % path)
	var duration: float = dialogue.response_duration(intro.infos[0], 0, doc)
	check(duration > 0.5 and duration < 10.0, "and its length times the line (%.2f s)" % duration)

	quests.stop_quest(vcg01)
	quests.reset_quest(vcg01)
	dialogue.reset()
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

## One step of game time: scripts, quests, then dialogue (voice loads waited
## for, so the run does not depend on thread timing).
func _step(script_server, quests, dialogue) -> void:
	script_server._process(STEP)
	quests._process(STEP)
	dialogue.wait_for_loads()
	dialogue._process(STEP)
