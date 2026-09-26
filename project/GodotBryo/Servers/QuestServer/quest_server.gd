extends Node

## Owns quests: their runtime state (QuestState, one per QUST), which are
## running, their stages, and when their scripts run. Autoloaded as
## QuestServer. Quests are world state, shared by every actor and player.

## Seconds between runs of a quest script whose QUST record gives no delay.
const DEFAULT_SCRIPT_DELAY := 5.0

var _states: Dictionary = {} # QUST FormID -> QuestState
var _elapsed: Dictionary = {} # QUST FormID -> seconds since its script last ran

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
		if entry.condition_count > 0:
			continue
		if (entry.flags & QuestLogEntry.FLAG_COMPLETE_QUEST) != 0:
			state.completed = true
		if (entry.flags & QuestLogEntry.FLAG_FAIL_QUEST) != 0:
			state.failed = true
		ScriptServer.run_result_script(entry.script_source, null)
		break

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
