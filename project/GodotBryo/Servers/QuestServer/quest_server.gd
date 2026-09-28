extends Node

## Owns quests: their runtime state (QuestState, one per QUST), which are
## running, their stages, and when their scripts run. Autoloaded as
## QuestServer. Quests are world state, shared by every actor and player.

## Emitted when a quest is granted: its first objective is displayed (none
## was displayed before).
signal quest_granted(quest: QuestBase)
## Emitted when the player's active quest changes; `quest` is null when cleared.
signal active_quest_changed(quest: QuestBase)

## Seconds between runs of a quest script whose QUST record gives no delay.
const DEFAULT_SCRIPT_DELAY := 5.0

var _states: Dictionary = {} # QUST FormID -> QuestState
var _elapsed: Dictionary = {} # QUST FormID -> seconds since its script last ran
var _warned_objectives: Dictionary = {} # "QUST FormID:index" -> true, one warning each
## Items whose quest-item state a script set (SetQuestObject), by base FormID:
## base FormID -> bool. Items not listed use their authored record flag.
var _quest_objects: Dictionary = {}

## The quest the player has selected as active (the Pip-Boy's active quest), or
## null. Not set by any shipped script; set by the player's UI.
var active_quest: QuestBase = null:
	set(value):
		if value == active_quest:
			return
		active_quest = value
		active_quest_changed.emit(value)

## Starts every quest flagged to run from the start of a new game.
func begin_game() -> void:
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) != "QUST":
			continue
		var quest := EsmServer.get_base(int(row["form_id"])) as QuestBase
		if quest != null and quest.starts_enabled:
			start_quest(quest)

## The runtime state of a quest: the same QuestState on every call, created on
## first use. Null for a record that is not a QUST.
func get_quest_state(quest: EsmBase) -> QuestState:
	if not quest is QuestBase:
		return null
	if not _states.has(quest.form_id):
		var state := QuestState.new()
		state.quest_form_id = quest.form_id
		state.quest = quest
		_states[quest.form_id] = state
	return _states[quest.form_id]

## Every QuestState created so far (a quest gets one on first use).
func get_quest_states() -> Array[QuestState]:
	var out: Array[QuestState] = []
	out.assign(_states.values())
	return out

func start_quest(quest: EsmBase) -> void:
	var state := get_quest_state(quest)
	if state != null and not state.running:
		state.running = true
		_elapsed[quest.form_id] = 0.0

func stop_quest(quest: EsmBase) -> void:
	var state := get_quest_state(quest)
	if state != null:
		state.running = false
		_elapsed.erase(quest.form_id)

func is_running(quest: EsmBase) -> bool:
	var state := get_quest_state(quest)
	return state != null and state.running

## Whether the quest is completed: by CompleteQuest, or by a stage whose log
## entry completes it.
func is_completed(quest: EsmBase) -> bool:
	var state := get_quest_state(quest)
	return state != null and state.completed

## Marks the quest completed. Whether it keeps running is not changed.
func complete_quest(quest: EsmBase) -> void:
	var state := get_quest_state(quest)
	if state != null:
		state.completed = true

## Marks the quest failed. Whether it keeps running is not changed.
func fail_quest(quest: EsmBase) -> void:
	var state := get_quest_state(quest)
	if state != null:
		state.failed = true

## Returns the quest to its state before any stage was set: stage 0, no
## stages done, no objectives displayed or completed, not completed or failed,
## script variables discarded (recreated at 0 on next use), authored script
## delay. Whether it is running is not changed.
func reset_quest(quest: EsmBase) -> void:
	var state := get_quest_state(quest)
	if state == null:
		return
	state.stage = 0
	state.stages_done.clear()
	state.objectives_displayed.clear()
	state.objectives_completed.clear()
	state.completed = false
	state.failed = false
	state.script_instance = null
	state.script_delay = -1.0

## Seconds between runs of the quest's script.
func get_script_delay(quest: EsmBase) -> float:
	var state := get_quest_state(quest)
	if state == null:
		return DEFAULT_SCRIPT_DELAY
	if state.script_delay >= 0.0:
		return state.script_delay
	var authored := (quest as QuestBase).script_delay
	return authored if authored > 0.0 else DEFAULT_SCRIPT_DELAY

func set_script_delay(quest: EsmBase, seconds: float) -> void:
	var state := get_quest_state(quest)
	if state != null:
		state.script_delay = maxf(seconds, 0.0)

func get_stage(quest: EsmBase) -> int:
	var state := get_quest_state(quest)
	return state.stage if state != null else 0

func is_stage_done(quest: EsmBase, stage: int) -> bool:
	var state := get_quest_state(quest)
	return state != null and state.stages_done.has(stage)

## Sets the quest's stage, marks it done and runs the stage's result script:
## that of its first log entry without conditions (conditions are not
## evaluated, so a stage whose entries all have conditions runs none). An entry
## flagged to complete or fail the quest marks it so.
func set_stage(quest: EsmBase, stage: int) -> void:
	var state := get_quest_state(quest)
	if state == null:
		return
	state.stage = stage
	state.stages_done[stage] = true
	var authored := (quest as QuestBase).get_stage(stage)
	if authored == null:
		return
	for entry in authored.log_entries:
		if not entry.conditions.is_empty():
			continue
		if (entry.flags & QuestLogEntry.FLAG_COMPLETE_QUEST) != 0:
			state.completed = true
		if (entry.flags & QuestLogEntry.FLAG_FAIL_QUEST) != 0:
			state.failed = true
		ScriptServer.run_result_script(entry.script_source, null)
		break

## Whether the objective is displayed. False for an index the quest does not
## define, with one warning per quest and index.
func is_objective_displayed(quest: EsmBase, index: int) -> bool:
	var state := _objective_state(quest, index)
	return state != null and state.objectives_displayed.has(index)

## Whether the objective is completed. False for an index the quest does not
## define, with one warning per quest and index.
func is_objective_completed(quest: EsmBase, index: int) -> bool:
	var state := _objective_state(quest, index)
	return state != null and state.objectives_completed.has(index)

## Displays (true) or hides (false) the objective. Does not change whether it
## is completed. Returns false and changes nothing for an index the quest does
## not define, with one warning per quest and index.
func set_objective_displayed(quest: EsmBase, index: int, displayed: bool) -> bool:
	var state := _objective_state(quest, index)
	if state == null:
		return false
	if displayed:
		var granted := state.objectives_displayed.is_empty()
		state.objectives_displayed[index] = true
		if granted:
			quest_granted.emit(quest)
	else:
		state.objectives_displayed.erase(index)
	return true

## Completes (true) or uncompletes (false) the objective. Does not change
## whether it is displayed. Returns false and changes nothing for an index the
## quest does not define, with one warning per quest and index.
func set_objective_completed(quest: EsmBase, index: int, completed: bool) -> bool:
	var state := _objective_state(quest, index)
	if state == null:
		return false
	if completed:
		state.objectives_completed[index] = true
	else:
		state.objectives_completed.erase(index)
	return true

## Completes every objective the quest defines. Whether each is displayed is
## not changed.
func complete_all_objectives(quest: EsmBase) -> void:
	var state := get_quest_state(quest)
	if state == null:
		return
	for objective in (quest as QuestBase).objectives:
		state.objectives_completed[objective.index] = true

## Whether `item` is a quest item: the state SetQuestObject last gave it, else
## its authored record flag (EsmBase.RECORD_FLAG_QUEST_ITEM).
func is_quest_object(item: EsmBase) -> bool:
	if item == null:
		return false
	if _quest_objects.has(item.form_id):
		return bool(_quest_objects[item.form_id])
	return (item.record_flags & EsmBase.RECORD_FLAG_QUEST_ITEM) != 0

## Makes `item` a quest item (true) or not (false), overriding its authored
## record flag.
func set_quest_object(item: EsmBase, is_quest_item: bool) -> void:
	if item != null:
		_quest_objects[item.form_id] = is_quest_item

## The quest's state when the quest defines objective `index`, else null. An
## undefined index on a QUST warns once per quest and index.
func _objective_state(quest: EsmBase, index: int) -> QuestState:
	if not quest is QuestBase:
		return null
	if (quest as QuestBase).get_objective(index) == null:
		var key := "%d:%d" % [quest.form_id, index]
		if not _warned_objectives.has(key):
			_warned_objectives[key] = true
			push_warning("QuestServer: %s (0x%08X) has no objective %d; it reads as not displayed or completed and cannot be set"
					% [quest.editor_id, quest.form_id, index])
		return null
	return get_quest_state(quest)

## Runs each running quest's script GameMode block once its delay has passed.
func _process(delta: float) -> void:
	for form_id: int in _elapsed.keys():
		var state: QuestState = _states.get(form_id)
		if state == null or not state.running:
			continue
		_elapsed[form_id] += delta
		if _elapsed[form_id] < get_script_delay(state.quest):
			continue
		_elapsed[form_id] = 0.0
		ScriptServer.run_quest_block(state.quest, "GameMode")
