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
		var first: ActorFaction = doc_base.factions[0]
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
