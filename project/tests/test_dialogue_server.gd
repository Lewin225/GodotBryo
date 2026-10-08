extends Node

## DialogueServer.choose_info() against real VCG01 dialogue, plus built INFOs
## for quest priority, Random sets and ANAM; and the actor condition functions
## dialogue uses (GetIsSex, GetIsVoiceType, GetInFaction, GetFactionRank).

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
	var doc: EsmReference = esm_server.find_reference_by_editor_id("DocMitchellREF")
	var player: ActorReference = esm_server.get_player_reference()
	var vcg01: QuestBase = esm_server.find_quest_by_editor_id("VCG01")
	quests.start_quest(vcg01)

	# VCG01Intro: 15 Say Once INFOs, each said once, in file order.
	var intro: DialogueTopicBase = esm_server.find_base_by_editor_id("VCG01Intro")
	var said: Array[DialogueInfoBase] = []
	for i in intro.infos.size() + 1:
		var info: DialogueInfoBase = dialogue.choose_info(intro, doc, player)
		if info == null:
			break
		said.append(info)
		dialogue.mark_said(info, doc)
	check(said == intro.infos, "VCG01Intro yields its %d INFOs in file order as each is said (%d said)" % [intro.infos.size(), said.size()])
	check(dialogue.choose_info(intro, doc, player) == null, "and nothing once all are said")
	dialogue.reset()

	# Say Once is per speaker.
	dialogue.mark_said(intro.infos[0], player)
	check(dialogue.has_said(intro.infos[0], player) and dialogue.choose_info(intro, doc, player) == intro.infos[0],
			"an INFO said by another actor (the player) is still Doc's to say")
	dialogue.reset()

	# VCG01DocReactions: the tested SPECIAL (VCG01 variable 5) and the player's sex.
	var reactions: DialogueTopicBase = esm_server.find_base_by_editor_id("VCG01DocReactions")
	var special: String = script_server.script_variable_name(vcg01.script_form_id, 5)
	var instance: ScriptInstance = script_server.get_quest_instance(vcg01)
	var player_base: NpcBase = player.base
	var authored_flags := player_base.acbs_flags
	instance.set_local(special, 1)
	player_base.acbs_flags = authored_flags & ~NpcBase.FLAG_FEMALE
	var male: DialogueInfoBase = dialogue.choose_info(reactions, doc, player)
	player_base.acbs_flags = authored_flags | NpcBase.FLAG_FEMALE
	var female: DialogueInfoBase = dialogue.choose_info(reactions, doc, player)
	player_base.acbs_flags = authored_flags
	check(male != null and male.form_id == 0x00104BDE and female != null and female.form_id == 0x00104BDF,
			"%s 1: \"Sorry, son\" to a male player, \"Sorry, little lady\" to a female one" % special)
	instance.set_local(special, 3)
	var three: DialogueInfoBase = dialogue.choose_info(reactions, doc, player)
	check(three != null and three.form_id == 0x00104BE1, "%s 3 picks 00104BE1 (%s)" % [special, "%08X" % three.form_id if three != null else "none"])
	instance.set_local(special, 0)

	# GREETING: Doc's is VCG01's while VCG01 runs.
	var greeting: DialogueTopicBase = esm_server.find_base_by_editor_id("GREETING")
	var greet: DialogueInfoBase = dialogue.choose_info(greeting, doc, player)
	check(greet != null and greet.quest == vcg01, "Doc's GREETING is VCG01's while it runs (%s)" % (greet.quest.editor_id if greet != null else "none"))
	quests.stop_quest(vcg01)
	var later: DialogueInfoBase = dialogue.choose_info(greeting, doc, player)
	check(later == null or later.quest != vcg01, "and not once VCG01 stops (%s)" % (later.quest.editor_id if later != null else "none"))
	quests.start_quest(vcg01)

	_check_built_infos(esm_server, quests, dialogue, doc, player, vcg01)
	_check_actor_functions(esm_server, script_server, doc, player)
	await _check_lines_keep_scripts(esm_server, quests, dialogue, doc, player)
	await _check_follow_ups(esm_server, quests, dialogue, doc, player)

	quests.stop_quest(vcg01)
	quests.reset_quest(vcg01)
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

## Quest priority across quests, Random sets ending at Random End, and ANAM.
func _check_built_infos(esm_server, quests, dialogue, doc: EsmReference, player: EsmReference, vcg01: QuestBase) -> void:
	var low: QuestBase = esm_server.find_quest_by_editor_id("VDialogueGoodspringsGeneric")
	quests.start_quest(low)
	var topic := DialogueTopicBase.new()
	var from_low := _info(0x7000001, low, 0)
	var from_vcg01 := _info(0x7000002, vcg01, 0)
	topic.infos = [from_low, from_vcg01]
	check(low.priority < vcg01.priority and dialogue.choose_info(topic, doc, player) == from_vcg01,
			"a higher-priority quest's INFO (VCG01, %d) is chosen over an earlier one of a lower (%d)" % [vcg01.priority, low.priority])
	quests.stop_quest(low)

	var random := DialogueInfoBase.FLAG_RANDOM
	var a := _info(0x7000010, vcg01, random)
	var b := _info(0x7000011, vcg01, random)
	var c := _info(0x7000012, vcg01, random | DialogueInfoBase.FLAG_RANDOM_END)
	var d := _info(0x7000013, vcg01, random)
	topic.infos = [a, b, c, d]
	var seen := {}
	for attempt in 200:
		dialogue.rng.seed = attempt
		seen[dialogue.choose_info(topic, doc, player)] = true
	check(seen.size() == 3 and seen.has(a) and seen.has(b) and seen.has(c), "a Random set is A, B and C, ending at C's Random End (%d chosen)" % seen.size())

	var someone_else := _info(0x7000020, vcg01, 0)
	someone_else.speaker_form_id = 0x00104C0D
	var docs := _info(0x7000021, vcg01, 0)
	docs.speaker_form_id = doc.base_form_id
	topic.infos = [someone_else, docs]
	check(dialogue.choose_info(topic, doc, player) == docs, "an INFO whose ANAM names another actor is not Doc's")

## Doc's farewell (VCG01DocMitchellTopic076, INFO 001057E7) hands VCG01 to
## VGenericTimer in its End script. Cut short by another line, or skipped to
## its end, it still runs.
## VCG01's farewell is reached by follow-ups (TCFU): the Pip-Boy line
## (001057E4) follows up into the vault suit line (001057E5 / E6, by sex), whose
## choices are topics 083-085; Doc's reply to 083 (0015E139) follows up into the
## farewell (001057E7, Goodbye), whose End script starts VGenericTimer.
func _check_follow_ups(esm_server, quests, dialogue, doc: EsmReference, player: EsmReference) -> void:
	var topic: DialogueTopicBase = esm_server.find_base_by_editor_id("VCG01DocMitchellTopic076")
	var timer: QuestBase = esm_server.find_quest_by_editor_id("VGenericTimer")
	var said: Array[String] = []
	var on_response := func(line: DialogueLine, _text: String) -> void:
		var entry := "%08X" % line.info.form_id
		if said.is_empty() or said.back() != entry:
			said.append(entry)
	dialogue.response_started.connect(on_response)
	var offered := [[]]
	var on_choices := func(choices: Array[DialogueChoice]) -> void:
		var names: Array[String] = []
		for choice in choices:
			names.append(choice.topic.editor_id)
		offered[0] = names
	dialogue.choices_ready.connect(on_choices)
	check(dialogue.start_conversation(doc, player, topic), "Doc starts a conversation on topic 076")
	await _skip_until(dialogue, doc, func() -> bool: return not (offered[0] as Array).is_empty())
	check(said.size() == 2 and said[0] == "001057E4" and (said[1] == "001057E5" or said[1] == "001057E6"), "the Pip-Boy line follows up into the vault suit line (%s)" % ", ".join(said))
	var index := (offered[0] as Array).find("VCG01DocMitchellTopic083")
	check(index != -1, "whose choices include topic 083 (%s)" % ", ".join(offered[0]))
	dialogue.choose(index)
	await _skip_until(dialogue, doc, func() -> bool: return dialogue.get_conversation_speaker() == null)
	dialogue.response_started.disconnect(on_response)
	dialogue.choices_ready.disconnect(on_choices)
	check(said.size() == 4 and said[2] == "0015E139" and said[3] == "001057E7", "Doc's reply to 083 follows up into the farewell (%s)" % ", ".join(said))
	check(dialogue.get_conversation_speaker() == null and quests.is_running(timer), "whose Goodbye ends the conversation and End script starts VGenericTimer")
	quests.stop_quest(timer)

## Skips Doc's lines, frame by frame, until `done` holds or 20 s pass.
func _skip_until(dialogue, doc: EsmReference, done: Callable) -> void:
	var deadline := Time.get_ticks_msec() + 20000
	while not done.call() and Time.get_ticks_msec() < deadline:
		dialogue.wait_for_loads()
		dialogue.skip(doc)
		await get_tree().process_frame

func _check_lines_keep_scripts(esm_server, quests, dialogue, doc: EsmReference, player: EsmReference) -> void:
	var topic: DialogueTopicBase = esm_server.find_base_by_editor_id("VCG01DocMitchellTopic076")
	var farewell: DialogueInfoBase = null
	for info in topic.infos:
		if info.form_id == 0x001057E7:
			farewell = info
	var timer: QuestBase = esm_server.find_quest_by_editor_id("VGenericTimer")
	var greeting: DialogueTopicBase = esm_server.find_base_by_editor_id("GREETING")

	dialogue.say(doc, topic, player, farewell)
	dialogue.say(doc, greeting, player)
	check(quests.is_running(timer), "a farewell cut short by another line still runs its End script (VGenericTimer started)")
	quests.stop_quest(timer)
	dialogue.end_conversation(false)

	var finished := [false]
	var on_finished := func(line: DialogueLine) -> void:
		if line.info == farewell:
			finished[0] = true
	dialogue.line_finished.connect(on_finished)
	dialogue.say(doc, topic, player, farewell)
	dialogue.wait_for_loads()
	for skip_index in farewell.responses.size():
		await get_tree().process_frame
		dialogue.skip(doc)
	for frame in 5:
		await get_tree().process_frame
	dialogue.line_finished.disconnect(on_finished)
	check(finished[0] and quests.is_running(timer), "skipping each of its %d responses finishes it, End script run" % farewell.responses.size())
	quests.stop_quest(timer)

func _info(form_id: int, quest: QuestBase, flags: int) -> DialogueInfoBase:
	var info := DialogueInfoBase.new()
	info.form_id = form_id
	info.quest = quest
	info.quest_form_id = quest.form_id
	info.flags = flags
	return info

## GetIsSex, GetIsVoiceType, GetInFaction and GetFactionRank on Doc Mitchell.
func _check_actor_functions(esm_server, script_server, doc: EsmReference, _player: EsmReference) -> void:
	var registry: ScriptFunctionRegistry = script_server.function_registry
	var ctx := ScriptExecutionContext.new(doc)
	check(registry.call_function("GetIsSex", ["Male"], ctx) == 1 and registry.call_function("GetIsSex", [1], ctx) == 0, "Doc is male")
	var voice: EsmBase = esm_server.find_base_by_editor_id("MaleUniqueDocMitchell")
	check(registry.call_function("GetIsVoiceType", [voice], ctx) == 1, "Doc's voice type is MaleUniqueDocMitchell")
	var doc_base: NpcBase = doc.base
	check(not doc_base.factions.is_empty(), "Doc's NPC_ lists factions (%d)" % doc_base.factions.size())
	if not doc_base.factions.is_empty():
		var first: FactionSubrecord = doc_base.factions[0]
		var faction: EsmBase = esm_server.get_base(first.faction_form_id)
		check(registry.call_function("GetInFaction", [faction], ctx) == 1 and registry.call_function("GetFactionRank", [faction], ctx) == first.rank,
				"Doc is in %s at rank %d" % [faction.editor_id, first.rank])
	var member_of := {}
	for entry in doc_base.factions:
		member_of[entry.faction_form_id] = true
	var other: EsmBase = null
	for row: Dictionary in esm_server.get_record_index():
		if other == null and String(row.get("record_type", "")) == "FACT" and not member_of.has(int(row["form_id"])):
			other = esm_server.get_base(int(row["form_id"]))
	check(registry.call_function("GetInFaction", [other], ctx) == 0 and registry.call_function("GetFactionRank", [other], ctx) == -1,
			"Doc is not in %s" % other.editor_id)
