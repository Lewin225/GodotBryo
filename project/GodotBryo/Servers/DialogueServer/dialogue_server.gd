extends Node

## Chooses what actors say, says it, and holds dialogue state: which actor has
## said which INFO, who has talked to the player, and the player's added
## topics. Autoloaded as DialogueServer. Topics and INFOs themselves are
## authored resources (DialogueTopicBase, DialogueInfoBase) from EsmServer.

## A response of a line starts: `text` is shown as a subtitle.
signal response_started(line: DialogueLine, text: String)
## A line finished: its end script and the speaker's SayToDone have run.
signal line_finished(line: DialogueLine)
## A conversation began: `speaker` talks to `listener` (the player).
signal conversation_started(speaker: EsmReference, listener: EsmReference)
## The speaker finished a line and the player chooses what next.
signal choices_ready(choices: Array[DialogueChoice])
## The conversation ended.
signal conversation_ended(speaker: EsmReference)

## The voice files' plugin folder: the only master loaded is FalloutNV.esm.
const VOICE_PLUGIN := "falloutnv.esm"
## Quest and topic editor IDs together longer than this are shortened in a
## voice file name: the quest to 10 characters, the topic to the rest.
const VOICE_NAME_LENGTH := 25
const VOICE_QUEST_LENGTH := 10

## A voice's falloff: full volume within this many metres of the speaker
## (AudioStreamPlayer3D.unit_size). No ESM or GECK setting gives voice range.
@export var voice_unit_size := 4.0
## A voice is not heard beyond this many metres.
@export var voice_max_distance := 40.0
## Height of the voice above a speaker with no 3D node, metres.
@export var voice_height := 1.6

var _said: Dictionary = {} # speaker instance_id -> {INFO FormID: game day said}
var _talked_to_player: Dictionary = {} # actor instance_id -> true
var _added_topics: Dictionary = {} # DIAL FormID -> true
var _lines: Dictionary = {} # speaker instance_id -> DialogueLine being said
var _streams: Dictionary = {} # voice file path -> AudioStream, or null when it does not load
var _lips: Dictionary = {} # voice file path -> LipReader of the .lip beside it, or null
var _tasks: Dictionary = {} # WorkerThreadPool task ID -> DialogueLine whose voice it loads
## The conversation being held, or null: its speaker, listener and the line
## the speaker is saying in it.
var _conversation_speaker: EsmReference = null
var _conversation_listener: EsmReference = null
var _conversation_line: DialogueLine = null
var _choices: Array[DialogueChoice] = []
var _top_level_topics: Array[DialogueTopicBase] = [] # built on first use
var _top_level_built := false
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

## `speaker` says the INFO `choose_info()` picks in `topic` to `listener`
## (null for Say). The INFO is marked said at once; the line starts when its
## voice files are loaded, on a worker thread when any is not cached (usually
## the next frame): its begin script runs on the speaker, then each response is
## said and played for its duration; when the last ends, the end script runs
## and the speaker's `SayToDone` block for the topic. A line the speaker is
## already saying is replaced. Returns the line, or null when no INFO
## qualifies.
func say(speaker: EsmReference, topic: DialogueTopicBase, listener: EsmReference, chosen: DialogueInfoBase = null) -> DialogueLine:
	var info := chosen if chosen != null else choose_info(topic, speaker, listener)
	if info == null or speaker == null:
		return null
	var line := DialogueLine.new()
	line.info = info
	line.topic = topic
	line.speaker = speaker
	line.listener = listener
	var missing := PackedStringArray()
	for i in info.responses.size():
		var path := voice_path(info, i, speaker)
		line.voice_paths.append(path)
		if not path.is_empty() and not _streams.has(path) and not missing.has(path):
			missing.append(path)
	_cut(_lines.get(speaker.instance_id))
	_lines[speaker.instance_id] = line
	mark_said(info, speaker)
	if missing.is_empty():
		_start(line)
	else:
		_tasks[WorkerThreadPool.add_task(_load_voice.bind(line, missing))] = line
	return line

## A line replaced before it ends still runs its scripts: its Begin script if
## it had not started, its End script and SayToDone; it ends as if finished,
## without continuing a conversation.
func _cut(line: DialogueLine) -> void:
	if line == null:
		return
	_lines.erase(line.speaker.instance_id)
	_stop(line)
	if not line.started:
		ScriptServer.run_result_script(line.info.begin_script_source, line.speaker, line.listener)
	ScriptServer.run_result_script(line.info.end_script_source, line.speaker, line.listener)
	ScriptServer.dispatch_event_for(line.speaker, "SayToDone", line.topic)
	line_finished.emit(line)

## Skips the response `speaker` is saying: the next one starts, and after the
## last the line finishes as usual (its End script runs). A line whose voice
## is still loading is not skipped.
func skip(speaker: EsmReference) -> void:
	var line := get_line(speaker)
	if line == null or not line.started or line.response_index >= line.durations.size():
		return
	line.elapsed = line.durations[line.response_index]

## A line `listener` is hearing (being said to it), or null.
func get_line_heard_by(listener: EsmReference) -> DialogueLine:
	if listener == null:
		return null
	for line: DialogueLine in _lines.values():
		if line.listener == listener:
			return line
	return null

## The line `speaker` is saying, or null.
func get_line(speaker: EsmReference) -> DialogueLine:
	return _lines.get(speaker.instance_id) if speaker != null else null

## Starts lines whose voice has loaded, then advances every started line by
## `delta` seconds, finishing those whose last response ends. In menu mode
## lines and their voices pause, except under the Dialog menu (a
## conversation), whose lines run.
func _process(delta: float) -> void:
	var paused := ScriptServer.is_menu_mode() and ScriptServer.get_menu() != ScriptServer.MENU_DIALOG
	_pause_voices(paused)
	if paused:
		return
	for task: int in _tasks.keys():
		if not WorkerThreadPool.is_task_completed(task):
			continue
		WorkerThreadPool.wait_for_task_completion(task)
		var loaded_line: DialogueLine = _tasks[task]
		_tasks.erase(task)
		_streams.merge(loaded_line.loaded)
		_lips.merge(loaded_line.loaded_lips)
		if _lines.get(loaded_line.speaker.instance_id) == loaded_line:
			_start(loaded_line)
	for line: DialogueLine in _lines.values():
		if not line.started:
			continue
		_place_voice(line)
		line.elapsed += delta
		while line.response_index < line.durations.size() and line.elapsed >= line.durations[line.response_index]:
			line.elapsed -= line.durations[line.response_index]
			line.response_index += 1
			if line.response_index < line.durations.size():
				_say_response(line)
		if line.response_index >= line.durations.size() and _lines.get(line.speaker.instance_id) == line:
			_finish(line)

## Blocks until every pending voice load has finished; the next _process
## starts their lines. For tests that step time by hand.
func wait_for_loads() -> void:
	for task: int in _tasks.keys():
		WorkerThreadPool.wait_for_task_completion(task)
	var lines: Array = _tasks.values()
	_tasks.clear()
	for line: DialogueLine in lines:
		_streams.merge(line.loaded)
		_lips.merge(line.loaded_lips)
		if _lines.get(line.speaker.instance_id) == line:
			_start(line)

## Reads and parses `paths` into `line.loaded`, and the .lip beside each
## into `line.loaded_lips`. Runs on a worker thread; ArchiveServer.read is
## thread-safe once initialised.
func _load_voice(line: DialogueLine, paths: PackedStringArray) -> void:
	for path in paths:
		var file: Dictionary = ArchiveServer.read(path)
		line.loaded[path] = AudioStreamOggVorbis.load_from_buffer(file["data"]) if bool(file.get("found", false)) else null
		line.loaded_lips[path] = _load_lip(lip_path(path))

## The .lip file beside a voice file: the same path ending in .lip.
static func lip_path(voice_file_path: String) -> String:
	return voice_file_path.get_basename() + ".lip"

## Reads and decodes a .lip file; null when it is missing or does not decode.
func _load_lip(path: String) -> LipReader:
	var file: Dictionary = ArchiveServer.read(path)
	if not bool(file.get("found", false)):
		return null
	var lip := LipReader.new()
	if not lip.load(file["data"], path):
		push_warning("DialogueServer: %s: %s" % [path, lip.get_last_error()])
		return null
	return lip

## Begins a line whose voice is loaded: sets each response's stream and
## duration, runs the begin script, and says the first response.
func _start(line: DialogueLine) -> void:
	for i in line.info.responses.size():
		var stream: AudioStream = _streams.get(line.voice_paths[i])
		line.streams.append(stream)
		line.lips.append(_lips.get(line.voice_paths[i]))
		line.durations.append(stream.get_length() if stream != null and stream.get_length() > 0.0 else _text_duration(line.info.responses[i].text))
	line.started = true
	ScriptServer.run_result_script(line.info.begin_script_source, line.speaker, line.listener)
	if _lines.get(line.speaker.instance_id) == line and not line.info.responses.is_empty():
		_say_response(line)

## Plays the current response's voice and shows it as a subtitle.
func _say_response(line: DialogueLine) -> void:
	var stream: AudioStream = line.streams[line.response_index]
	if stream != null:
		if line.voice_player == null:
			line.voice_player = AudioStreamPlayer3D.new()
			line.voice_player.unit_size = voice_unit_size
			line.voice_player.max_distance = voice_max_distance
			add_child(line.voice_player)
		line.voice_player.stream = stream
		_place_voice(line)
		line.voice_player.play()
	elif line.voice_player != null:
		line.voice_player.stop()
	response_started.emit(line, line.current_text())

func _finish(line: DialogueLine) -> void:
	_lines.erase(line.speaker.instance_id)
	_stop(line)
	ScriptServer.run_result_script(line.info.end_script_source, line.speaker, line.listener)
	ScriptServer.dispatch_event_for(line.speaker, "SayToDone", line.topic)
	line_finished.emit(line)
	if line == _conversation_line:
		_continue_conversation(line)

## `speaker` starts a conversation with `listener` (the player): the Dialog
## menu opens, the speaker has talked to the player, and says `topic`'s INFO,
## GREETING when none is given. After each line the player chooses
## (choices_ready) until a Goodbye INFO, no choice left, or end_conversation().
## Returns false, starting nothing, when no INFO qualifies.
func start_conversation(speaker: EsmReference, listener: EsmReference, topic: DialogueTopicBase = null) -> bool:
	if speaker == null:
		return false
	if topic == null:
		topic = EsmServer.find_base_by_editor_id("GREETING") as DialogueTopicBase
	var info := choose_info(topic, speaker, listener)
	if info == null:
		return false
	if _conversation_speaker != null:
		end_conversation(false)
	_conversation_speaker = speaker
	_conversation_listener = listener
	set_talked_to_player(speaker)
	ScriptServer.enter_menu(ScriptServer.MENU_DIALOG)
	conversation_started.emit(speaker, listener)
	_say_in_conversation(topic, info)
	return true

## The player chooses choice `index` of the last choices_ready: the speaker
## says its topic.
func choose(index: int) -> void:
	if _conversation_speaker == null or index < 0 or index >= _choices.size():
		return
	var choice := _choices[index]
	_choices.clear()
	_say_in_conversation(choice.topic)

## Ends the conversation: the Dialog menu closes. With `say_goodbye` (the
## player leaving) the speaker says GOODBYE, which the GECK's Topics Tab says
## is used when the player exits the dialogue menu.
func end_conversation(say_goodbye := true) -> void:
	var speaker := _conversation_speaker
	if speaker == null:
		return
	var listener := _conversation_listener
	_conversation_speaker = null
	_conversation_listener = null
	_conversation_line = null
	_choices.clear()
	ScriptServer.exit_menu(ScriptServer.MENU_DIALOG)
	conversation_ended.emit(speaker)
	if say_goodbye:
		say(speaker, EsmServer.find_base_by_editor_id("GOODBYE") as DialogueTopicBase, listener)

## The speaker of the conversation being held, or null.
## The one the speaker is talking to in the current conversation, or null.
func get_conversation_listener() -> EsmReference:
	return _conversation_listener

func get_conversation_speaker() -> EsmReference:
	return _conversation_speaker

## The choices offered after the speaker's last line.
func get_choices() -> Array[DialogueChoice]:
	return _choices

## The choices after `info`: its Link To topics when it has any, else the
## topic list (top-level topics, then the player's added topics), each with an
## INFO the speaker would say and ordered by topic priority, highest first.
func choices_after(info: DialogueInfoBase, speaker: EsmReference, listener: EsmReference) -> Array[DialogueChoice]:
	var topics: Array[DialogueTopicBase] = []
	if not info.link_to_form_ids.is_empty():
		for form_id in info.link_to_form_ids:
			var linked := EsmServer.get_base(form_id) as DialogueTopicBase
			if linked != null:
				topics.append(linked)
	else:
		var listed: Array[DialogueTopicBase] = []
		for topic in _get_top_level_topics():
			listed.append(topic)
		var added: Array[DialogueTopicBase] = []
		for form_id: int in _added_topics:
			var topic := EsmServer.get_base(form_id) as DialogueTopicBase
			if topic != null and not topic.is_top_level():
				added.append(topic)
		var by_priority := func(a: DialogueTopicBase, b: DialogueTopicBase) -> bool: return a.priority > b.priority
		listed.sort_custom(by_priority)
		added.sort_custom(by_priority)
		topics.append_array(listed)
		topics.append_array(added)
	var choices: Array[DialogueChoice] = []
	for topic in topics:
		var chosen := choose_info(topic, speaker, listener)
		if chosen == null:
			continue
		var choice := DialogueChoice.new()
		choice.topic = topic
		choice.info = chosen
		choice.text = chosen.prompt if not chosen.prompt.is_empty() else topic.full_name
		choices.append(choice)
	return choices

func _say_in_conversation(topic: DialogueTopicBase, chosen: DialogueInfoBase = null) -> void:
	var line := say(_conversation_speaker, topic, _conversation_listener, chosen)
	if line == null:
		end_conversation(false)
		return
	_conversation_line = line
	for form_id in line.info.add_topic_form_ids:
		add_topic(EsmServer.get_base(form_id) as DialogueTopicBase)

## After a line in a conversation: its first follow-up INFO (TCFU) the speaker
## qualifies for is said next; else a Goodbye INFO ends the conversation; else
## the player chooses. VCG01's farewell is reached only this way (the door
## greeting follows up into the Pip-Boy line, that into the vault suit line,
## and the replies to its choices into the farewell, whose End script hands
## VCG01 to stage 200).
func _continue_conversation(line: DialogueLine) -> void:
	_conversation_line = null
	var follow_up := _follow_up(line)
	if follow_up != null:
		_say_in_conversation(EsmServer.get_base(follow_up.topic_form_id) as DialogueTopicBase, follow_up)
		return
	if line.info.has_flag(DialogueInfoBase.FLAG_GOODBYE):
		end_conversation(false)
		return
	_choices = choices_after(line.info, _conversation_speaker, _conversation_listener)
	if _choices.is_empty():
		end_conversation(false)
		return
	choices_ready.emit(_choices)

## Every top-level DIAL (2,283 in FalloutNV.esm), found once: each DIAL's raw
## DATA flags are read, and only top-level topics (with their INFOs) loaded.
func _get_top_level_topics() -> Array[DialogueTopicBase]:
	if not _top_level_built:
		_top_level_built = true
		for row: Dictionary in EsmServer.get_record_index():
			if String(row.get("record_type", "")) != "DIAL":
				continue
			var raw: Dictionary = EsmServer.reader.get_record_data(int(row["form_id"]))
			for sub: Dictionary in raw.get("subrecords", []):
				if String(sub.get("type", "")) != "DATA":
					continue
				var data: PackedByteArray = sub.get("data", PackedByteArray())
				if data.size() >= 2 and (data[1] & DialogueTopicBase.FLAG_TOP_LEVEL) != 0:
					_top_level_topics.append(EsmServer.get_base(int(row["form_id"])) as DialogueTopicBase)
	return _top_level_topics

## Puts a line's voice at its speaker's eyes: its ActorHeadTracking's eye point
## when it has a 3D node (an NPC's, or the player's body), else its position
## plus voice_height, so a speaker with no node is heard from where it stands.
## A speaker in another space than the player is silent (spaces' coordinates
## overlap).
func _place_voice(line: DialogueLine) -> void:
	if line.voice_player == null or line.speaker == null:
		return
	line.voice_player.global_position = speaker_voice_position(line.speaker)
	var player := ScriptServer.player_reference
	var same_space := player == null or player.current_space_form_id == line.speaker.current_space_form_id
	line.voice_player.volume_db = 0.0 if same_space else -80.0
	# The player's own conversation is heard at any distance: no falloff.
	if _is_player_conversation_line(line):
		line.voice_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
		line.voice_player.max_distance = 0.0
	else:
		line.voice_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		line.voice_player.max_distance = voice_max_distance

## Whether `line` is said between the two sides of a conversation with the
## player.
func _is_player_conversation_line(line: DialogueLine) -> bool:
	var player := ScriptServer.player_reference
	if player == null or _conversation_speaker == null:
		return false
	if _conversation_speaker != player and _conversation_listener != player:
		return false
	var sides := [_conversation_speaker, _conversation_listener]
	return sides.has(line.speaker) and (line.listener == null or sides.has(line.listener))

## Where `speaker`'s voice comes from (Godot space).
func speaker_voice_position(speaker: EsmReference) -> Vector3:
	var actor_node: EsmActorNode = null
	var controller := EsmNode.node_for(speaker) as NpcController
	if controller != null:
		actor_node = controller.actor
	var player := ScriptServer.player_node as PlayerController
	if actor_node == null and player != null and player.possessed == speaker:
		actor_node = player.actor
	if actor_node != null and actor_node.is_inside_tree() and actor_node.head_tracking != null:
		return actor_node.head_tracking.get_eye_position()
	return EsmReferencePhysicaliser.GAMEBRYO_TO_GODOT_BASIS * speaker.position + Vector3.UP * voice_height

## Pauses or resumes every line's voice.
func _pause_voices(paused: bool) -> void:
	for line: DialogueLine in _lines.values():
		if line.voice_player != null:
			line.voice_player.stream_paused = paused

## Stops and frees a line's voice player.
func _stop(line: DialogueLine) -> void:
	if line != null and line.voice_player != null:
		line.voice_player.queue_free()
		line.voice_player = null

## Seconds response `index` of `info` takes as `speaker` says it, loading its
## voice file on the calling thread if it is not cached: the file's length,
## or, with none, the text estimate.
func response_duration(info: DialogueInfoBase, index: int, speaker: EsmReference) -> float:
	var path := voice_path(info, index, speaker)
	if not path.is_empty() and not _streams.has(path):
		var file: Dictionary = ArchiveServer.read(path)
		_streams[path] = AudioStreamOggVorbis.load_from_buffer(file["data"]) if bool(file.get("found", false)) else null
	var stream: AudioStream = _streams.get(path)
	return stream.get_length() if stream != null and stream.get_length() > 0.0 else _text_duration(info.responses[index].text)

## An unvoiced response's duration: its text at fNoticeTextTimePerCharacter
## seconds a character (an estimate; the original's rule is not known).
func _text_duration(text: String) -> float:
	var per_character: Variant = EsmServer.get_game_setting("fNoticeTextTimePerCharacter")
	return text.length() * (float(per_character) if per_character != null else 0.08)

## The voice file of response `index` of `info` as `speaker` says it:
## sound\voice\<plugin>\<voice type>\<quest>_<topic>_<INFO>_<n>.ogg, or ""
## when the speaker has no voice type. Lowercase, as the archive stores it.
func voice_path(info: DialogueInfoBase, index: int, speaker: EsmReference) -> String:
	var voice_type := _voice_type(speaker)
	var quest_id := info.quest.editor_id if info.quest != null else ""
	var topic: EsmBase = EsmServer.get_base(info.topic_form_id)
	var topic_id := topic.editor_id if topic != null else ""
	if voice_type == null or quest_id.is_empty() or topic_id.is_empty() or index >= info.responses.size():
		return ""
	if quest_id.length() + topic_id.length() > VOICE_NAME_LENGTH:
		quest_id = quest_id.left(VOICE_QUEST_LENGTH)
		topic_id = topic_id.left(VOICE_NAME_LENGTH - quest_id.length())
	var file := "%s_%s_%08x_%d.ogg" % [quest_id, topic_id, info.form_id, info.responses[index].response_number]
	return ("sound\\voice\\%s\\%s\\%s" % [VOICE_PLUGIN, voice_type.editor_id, file]).to_lower()

## The speaker's VTYP: its NPC_ or CREA VTCK (from its template when that
## supplies traits) or its TACT VNAM.
func _voice_type(speaker: EsmReference) -> EsmBase:
	if speaker == null or speaker.base == null:
		return null
	if speaker.base is ActorBase:
		return ActorBase.template_source(speaker.base, ActorBase.TEMPLATE_USE_TRAITS).voice_type
	var form_id: int = speaker.base.get("voice_type_form_id") if speaker.base.get("voice_type_form_id") != null else 0
	return EsmServer.get_base(form_id) if form_id != 0 else null

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
	if _conversation_speaker != null:
		end_conversation(false)
	for line: DialogueLine in _lines.values():
		_stop(line)
	_lines.clear()
	for task: int in _tasks.keys():
		WorkerThreadPool.wait_for_task_completion(task)
	_tasks.clear()

## The first of `line`'s follow-up INFOs (TCFU, in order) its speaker
## qualifies for, or null.
func _follow_up(line: DialogueLine) -> DialogueInfoBase:
	if line.info.follow_up_form_ids.is_empty():
		return null
	var context := ConditionContext.new(line.speaker, line.listener)
	context.owner_label = "INFO %08X follow-up" % line.info.form_id
	for form_id in line.info.follow_up_form_ids:
		var info := EsmServer.get_base(form_id) as DialogueInfoBase
		if info != null and _qualifies(info, line.speaker, context):
			return info
	return null

func _qualifies(info: DialogueInfoBase, speaker: EsmReference, context: ConditionContext) -> bool:
	if info.quest == null or not QuestServer.is_running(info.quest):
		return false
	var required_speaker := info.get_required_speaker()
	if required_speaker != 0 and (speaker == null or speaker.base_form_id != required_speaker):
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
