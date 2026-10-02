extends Node

## Chooses what actors say, says it, and holds dialogue state: which actor has
## said which INFO, who has talked to the player, and the player's added
## topics. Autoloaded as DialogueServer. Topics and INFOs themselves are
## authored resources (DialogueTopicBase, DialogueInfoBase) from EsmServer.

## A response of a line starts: `text` is shown as a subtitle.
signal response_started(line: DialogueLine, text: String)
## A line finished: its end script and the speaker's SayToDone have run.
signal line_finished(line: DialogueLine)

## The voice files' plugin folder: the only master loaded is FalloutNV.esm.
const VOICE_PLUGIN := "falloutnv.esm"
## Quest and topic editor IDs together longer than this are shortened in a
## voice file name: the quest to 10 characters, the topic to the rest.
const VOICE_NAME_LENGTH := 25
const VOICE_QUEST_LENGTH := 10

var _said: Dictionary = {} # speaker instance_id -> {INFO FormID: game day said}
var _talked_to_player: Dictionary = {} # actor instance_id -> true
var _added_topics: Dictionary = {} # DIAL FormID -> true
var _lines: Dictionary = {} # speaker instance_id -> DialogueLine being said
var _streams: Dictionary = {} # voice file path -> AudioStream, or null when it does not load
var _tasks: Dictionary = {} # WorkerThreadPool task ID -> DialogueLine whose voice it loads
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
func say(speaker: EsmReference, topic: DialogueTopicBase, listener: EsmReference) -> DialogueLine:
	var info := choose_info(topic, speaker, listener)
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
	_stop(_lines.get(speaker.instance_id))
	_lines[speaker.instance_id] = line
	mark_said(info, speaker)
	if missing.is_empty():
		_start(line)
	else:
		_tasks[WorkerThreadPool.add_task(_load_voice.bind(line, missing))] = line
	return line

## The line `speaker` is saying, or null.
func get_line(speaker: EsmReference) -> DialogueLine:
	return _lines.get(speaker.instance_id) if speaker != null else null

## Starts lines whose voice has loaded, then advances every started line by
## `delta` seconds, finishing those whose last response ends.
func _process(delta: float) -> void:
	for task: int in _tasks.keys():
		if not WorkerThreadPool.is_task_completed(task):
			continue
		WorkerThreadPool.wait_for_task_completion(task)
		var loaded_line: DialogueLine = _tasks[task]
		_tasks.erase(task)
		_streams.merge(loaded_line.loaded)
		if _lines.get(loaded_line.speaker.instance_id) == loaded_line:
			_start(loaded_line)
	for line: DialogueLine in _lines.values():
		if not line.started:
			continue
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
		if _lines.get(line.speaker.instance_id) == line:
			_start(line)

## Reads and parses `paths` into `line.loaded`. Runs on a worker thread;
## ArchiveServer.read is thread-safe once initialised.
func _load_voice(line: DialogueLine, paths: PackedStringArray) -> void:
	for path in paths:
		var file: Dictionary = ArchiveServer.read(path)
		line.loaded[path] = AudioStreamOggVorbis.load_from_buffer(file["data"]) if bool(file.get("found", false)) else null

## Begins a line whose voice is loaded: sets each response's stream and
## duration, runs the begin script, and says the first response.
func _start(line: DialogueLine) -> void:
	for i in line.info.responses.size():
		var stream: AudioStream = _streams.get(line.voice_paths[i])
		line.streams.append(stream)
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
			line.voice_player = AudioStreamPlayer.new()
			add_child(line.voice_player)
		line.voice_player.stream = stream
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
	var source := ActorStats.template_source(speaker.base, ActorStats.TEMPLATE_USE_TRAITS) if speaker.base.get("actor_stats") != null else speaker.base
	var form_id: int = source.get("voice_type_form_id") if source != null and source.get("voice_type_form_id") != null else 0
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
	for line: DialogueLine in _lines.values():
		_stop(line)
	_lines.clear()
	for task: int in _tasks.keys():
		WorkerThreadPool.wait_for_task_completion(task)
	_tasks.clear()

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
