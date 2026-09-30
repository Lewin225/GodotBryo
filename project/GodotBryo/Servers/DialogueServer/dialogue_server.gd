extends Node

## Chooses what actors say and holds dialogue state: which actor has said
## which INFO, who has talked to the player, and the player's added topics.
## Autoloaded as DialogueServer. Topics and INFOs themselves are authored
## resources (DialogueTopicBase, DialogueInfoBase) from EsmServer.

var _said: Dictionary = {} # speaker instance_id -> {INFO FormID: game day said}
var _talked_to_player: Dictionary = {} # actor instance_id -> true
var _added_topics: Dictionary = {} # DIAL FormID -> true
## Picks among a set of Random INFOs.
var rng := RandomNumberGenerator.new()

## The INFO `speaker` says in `topic` to `listener`, or null when none
## qualifies. The topic's INFOs of running quests are taken by quest priority,
## highest first, in file order within a priority; the first that qualifies
## (quest conditions, not spent by Say Once or Say Once a Day, ANAM speaker,
## its own conditions, with the speaker as subject and the listener as target)
## is said. A qualifying Random INFO instead starts a set: it and the
## qualifying Random INFOs after it, up to one flagged Random End, one chosen
## at random.
func choose_info(topic: DialogueTopicBase, speaker: EsmReference, listener: EsmReference) -> DialogueInfoBase:
	if topic == null:
		return null
	var context := ConditionContext.new(speaker, listener)
	context.owner_label = "DIAL %s" % topic.editor_id
	var ordered := _by_quest_priority(topic.infos)
	for i in ordered.size():
		var info: DialogueInfoBase = ordered[i]
		if not _qualifies(info, speaker, context):
			continue
		if not info.has_flag(DialogueInfoBase.FLAG_RANDOM):
			return info
		var random_set: Array[DialogueInfoBase] = [info]
		if not info.has_flag(DialogueInfoBase.FLAG_RANDOM_END):
			for j in range(i + 1, ordered.size()):
				var next: DialogueInfoBase = ordered[j]
				if not _qualifies(next, speaker, context):
					continue
				if not next.has_flag(DialogueInfoBase.FLAG_RANDOM):
					break
				random_set.append(next)
				if next.has_flag(DialogueInfoBase.FLAG_RANDOM_END):
					break
		return random_set[rng.randi_range(0, random_set.size() - 1)]
	return null

## Records that `speaker` said `info`, for Say Once and Say Once a Day.
func mark_said(info: DialogueInfoBase, speaker: EsmReference) -> void:
	if info == null or speaker == null:
		return
	var said: Dictionary = _said.get_or_add(speaker.instance_id, {})
	said[info.form_id] = _game_day()

## Whether `speaker` has said `info`.
func has_said(info: DialogueInfoBase, speaker: EsmReference) -> bool:
	return info != null and speaker != null and _said.get(speaker.instance_id, {}).has(info.form_id)

## Records that `actor` has talked to the player (GetTalkedToPC).
func set_talked_to_player(actor: EsmReference) -> void:
	if actor != null:
		_talked_to_player[actor.instance_id] = true

func has_talked_to_player(actor: EsmReference) -> bool:
	return actor != null and _talked_to_player.has(actor.instance_id)

## Adds `topic` to the player's known topics (AddTopic, INFO Add Topics).
func add_topic(topic: DialogueTopicBase) -> void:
	if topic != null:
		_added_topics[topic.form_id] = true

func has_topic(topic: DialogueTopicBase) -> bool:
	return topic != null and _added_topics.has(topic.form_id)

## Clears all dialogue state, as for a new game.
func reset() -> void:
	_said.clear()
	_talked_to_player.clear()
	_added_topics.clear()

func _qualifies(info: DialogueInfoBase, speaker: EsmReference, context: ConditionContext) -> bool:
	if info.quest == null or not QuestServer.is_running(info.quest):
		return false
	if info.speaker_form_id != 0 and (speaker == null or speaker.base_form_id != info.speaker_form_id):
		return false
	if info.has_flag(DialogueInfoBase.FLAG_SAY_ONCE) and has_said(info, speaker):
		return false
	if (info.flags_2 & DialogueInfoBase.FLAG_SAY_ONCE_A_DAY) != 0 and speaker != null \
			and int(_said.get(speaker.instance_id, {}).get(info.form_id, -1)) == _game_day():
		return false
	if not ScriptServer.evaluate_conditions(info.quest.conditions, context):
		return false
	return ScriptServer.evaluate_conditions(info.conditions, context)

## `infos` ordered by their quest's priority, highest first, keeping file
## order within a priority.
static func _by_quest_priority(infos: Array[DialogueInfoBase]) -> Array[DialogueInfoBase]:
	var by_priority: Dictionary = {} # priority -> Array[DialogueInfoBase]
	for info in infos:
		var priority: int = info.quest.priority if info.quest != null else 0
		var bucket: Array = by_priority.get_or_add(priority, [])
		bucket.append(info)
	var priorities: Array = by_priority.keys()
	priorities.sort()
	priorities.reverse()
	var ordered: Array[DialogueInfoBase] = []
	for priority in priorities:
		ordered.append_array(by_priority[priority])
	return ordered

func _game_day() -> int:
	return int(floorf(float(ScriptServer.function_registry.call_function("GameDaysPassed", [], ScriptExecutionContext.new(null)))))
