extends Node

## What choosing a GREETING costs: DialogueServer.choose_info(GREETING) for
## SAMPLE placed NPCs speaking to the player, timed on the first pass (first
## use of each condition's forms) and a second pass, with the INFO each gets.

const SAMPLE := 30

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	QuestServer.begin_game()
	var player := EsmServer.get_player_reference()
	ScriptServer.player_reference = player
	var greeting := EsmServer.find_base_by_editor_id("GREETING") as DialogueTopicBase
	print("GREETING: %d INFOs" % greeting.infos.size())
	var actors: Array = EsmServer.get_all_placed_actor_references()
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var sample := []
	for i in SAMPLE:
		sample.append(actors[rng.randi_range(0, actors.size() - 1)])
	for pass_name in ["first", "second"]:
		var total := 0
		var worst := 0
		var chosen := []
		for speaker: ActorReference in sample:
			var started := Time.get_ticks_usec()
			var info := DialogueServer.choose_info(greeting, speaker, player)
			var elapsed := Time.get_ticks_usec() - started
			total += elapsed
			worst = maxi(worst, elapsed)
			chosen.append("%08X" % info.form_id if info != null else "-")
		print("%s pass: mean %.1f ms, worst %.1f ms per choose_info" % [pass_name, total / 1000.0 / SAMPLE, worst / 1000.0])
		if pass_name == "second":
			print("chosen: %s" % ", ".join(chosen))
	_check_skip_changes_nothing(greeting, sample, player)
	get_tree().quit()

## The required-speaker skip must not change any choice: each speaker's
## choice with it, against the choice with every INFO's required speaker
## forced to none (full evaluation), the random generator seeded alike.
func _check_skip_changes_nothing(greeting: DialogueTopicBase, sample: Array, player: ActorReference) -> void:
	var with_skip := []
	for speaker: ActorReference in sample:
		DialogueServer.rng.seed = 99
		var info := DialogueServer.choose_info(greeting, speaker, player)
		with_skip.append(info.form_id if info != null else 0)
	var skipping := 0
	for info: DialogueInfoBase in greeting.infos:
		if info.get_required_speaker() != 0:
			skipping += 1
		info._required_speaker = 0
	var differences := 0
	for index in sample.size():
		DialogueServer.rng.seed = 99
		var info := DialogueServer.choose_info(greeting, sample[index], player)
		if (info.form_id if info != null else 0) != with_skip[index]:
			differences += 1
	print("%d of %d GREETING INFOs name a required speaker; choices that differ without the skip: %d of %d" % [skipping, greeting.infos.size(), differences, sample.size()])
