extends Control

## Debug Tools window (game.tscn) -> TabContainer -> "Quests" tab. Every QUST
## with its QuestServer state: running, stage, objectives, completion, and the
## player's active quest, which this tab sets in place of the Pip-Boy. Show
## Script opens the quest's script in the Script Engine tab.

## Filter dropdown ids, in the scene's item order.
enum Show { ALL, GRANTED, RUNNING, COMPLETED, FAILED }

const REFRESH_INTERVAL_SEC := 0.5

@onready var _summary: RichTextLabel = $Margin/VBox/Summary
@onready var _filter: LineEdit = $Margin/VBox/FilterRow/Filter
@onready var _show: OptionButton = $Margin/VBox/FilterRow/Show
@onready var _list: ItemList = $Margin/VBox/HSplit/QuestList
@onready var _details: RichTextLabel = $Margin/VBox/HSplit/Right/Details
@onready var _set_active: Button = $Margin/VBox/HSplit/Right/Buttons/SetActive
@onready var _clear_active: Button = $Margin/VBox/HSplit/Right/Buttons/ClearActive
@onready var _show_script: Button = $Margin/VBox/HSplit/Right/Buttons/ShowScript
@onready var _objectives: RichTextLabel = $Margin/VBox/HSplit/Right/Objectives
@onready var _stages: RichTextLabel = $Margin/VBox/HSplit/Right/Stages

var _quests: Array[QuestBase] = [] # every QUST, sorted by editor ID
var _listed: Array[QuestBase] = [] # the quests shown in _list, in order
var _listed_text: PackedStringArray = [] # each listed item's text, as last rendered
var _selected: QuestBase = null
var _since_refresh := 0.0


func _ready() -> void:
	_filter.text_changed.connect(func(_text: String) -> void: _refresh())
	_show.item_selected.connect(func(_index: int) -> void: _refresh())
	_list.item_selected.connect(_on_quest_selected)
	_set_active.pressed.connect(func() -> void:
		if _selected != null:
			QuestServer.active_quest = _selected
		_refresh())
	_clear_active.pressed.connect(func() -> void:
		QuestServer.active_quest = null
		_refresh())
	_show_script.pressed.connect(_open_script)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_since_refresh += delta
	if _since_refresh >= REFRESH_INTERVAL_SEC or _quests.is_empty():
		_since_refresh = 0.0
		_refresh()


func _refresh() -> void:
	if _quests.is_empty():
		_load_quests()
	var needle := _filter.text.strip_edges().to_lower()
	var show_filter := _show.get_selected_id()
	var counts := {"running": 0, "granted": 0, "completed": 0, "failed": 0}
	var listed: Array[QuestBase] = []
	var listed_text: PackedStringArray = []
	for quest in _quests:
		var state: QuestState = QuestServer.get_quest_state(quest)
		var granted := not state.objectives_displayed.is_empty()
		counts["running"] += int(state.running)
		counts["granted"] += int(granted)
		counts["completed"] += int(state.completed)
		counts["failed"] += int(state.failed)
		if not _passes(show_filter, state, granted):
			continue
		if not needle.is_empty() and not quest.editor_id.to_lower().contains(needle) and not quest.full_name.to_lower().contains(needle):
			continue
		listed.append(quest)
		listed_text.append("%s %s" % [_markers(quest, state, granted), _label(quest)])
	_update_list(listed, listed_text)
	var active := QuestServer.active_quest
	_set_text(_summary, "[b]%d[/b] quests   •   [color=#e5c07b]★ active:[/color] %s   •   [color=#61afef]● granted[/color] %d   •   [color=#98c379]▶ running[/color] %d   •   ✔ completed %d   •   [color=#e06c75]✖ failed[/color] %d   •   showing %d" % [
		_quests.size(), _label(active) if active != null else "[color=#7f848e]none[/color]",
		counts["granted"], counts["running"], counts["completed"], counts["failed"], _listed.size()])
	_show_selected()


## Brings the ItemList in line with `listed`: only changed item texts are set
## when the same quests are listed, and the list is rebuilt only when the set
## of listed quests changes. Rebuilding every refresh resets hover and scroll
## and relays out the whole list.
func _update_list(listed: Array[QuestBase], listed_text: PackedStringArray) -> void:
	if listed == _listed:
		for i in listed_text.size():
			if listed_text[i] != _listed_text[i]:
				_list.set_item_text(i, listed_text[i])
		_listed_text = listed_text
		return
	_listed = listed
	_listed_text = listed_text
	_list.clear()
	for i in listed.size():
		_list.add_item(listed_text[i])
		if listed[i] == _selected:
			_list.select(i)


## Assigns a label's text only when it changes: setting a RichTextLabel's text
## reparses its BBCode and relays it out.
static func _set_text(label: RichTextLabel, text: String) -> void:
	if label.text != text:
		label.text = text


func _load_quests() -> void:
	if not EsmServer.is_ready():
		return
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) != "QUST":
			continue
		var quest := EsmServer.get_base(int(row["form_id"])) as QuestBase
		if quest != null:
			_quests.append(quest)
	_quests.sort_custom(func(a: QuestBase, b: QuestBase) -> bool: return a.editor_id.naturalnocasecmp_to(b.editor_id) < 0)


## Whether a quest passes the Show filter. Granted means at least one objective
## is displayed.
static func _passes(show_filter: int, state: QuestState, granted: bool) -> bool:
	match show_filter:
		Show.GRANTED: return granted
		Show.RUNNING: return state.running
		Show.COMPLETED: return state.completed
		Show.FAILED: return state.failed
	return true


static func _markers(quest: QuestBase, state: QuestState, granted: bool) -> String:
	return "%s%s%s%s" % [
		"★" if quest == QuestServer.active_quest else "  ",
		"●" if granted else "  ",
		"▶" if state.running else "  ",
		"✖" if state.failed else ("✔" if state.completed else "  ")]


static func _label(quest: QuestBase) -> String:
	if quest.full_name.is_empty():
		return quest.editor_id
	return "%s — %s" % [quest.editor_id, quest.full_name]


func _on_quest_selected(index: int) -> void:
	if index >= 0 and index < _listed.size():
		_selected = _listed[index]
	_show_selected()


func _show_selected() -> void:
	var quest := _selected
	_set_active.disabled = quest == null or quest == QuestServer.active_quest
	_clear_active.disabled = QuestServer.active_quest == null
	_show_script.disabled = quest == null or quest.script_form_id == 0
	if quest == null:
		_set_text(_details, "[color=#7f848e]Select a quest.[/color]")
		_set_text(_objectives, "")
		_set_text(_stages, "")
		return
	var state: QuestState = QuestServer.get_quest_state(quest)
	var script_name := "[color=#7f848e]none[/color]"
	if quest.script_form_id != 0:
		var script_base: EsmBase = EsmServer.get_base(quest.script_form_id)
		script_name = "%s (0x%08X)" % [script_base.editor_id if script_base != null else "?", quest.script_form_id]
	_set_text(_details, "[b]%s[/b] [color=#98c379](0x%08X)[/color]%s\n[b]Stage:[/b] %d   •   [b]Running:[/b] %s   •   [b]Completed:[/b] %s   •   [b]Failed:[/b] %s   •   [b]Active:[/b] %s\n[b]Priority:[/b] %d   •   [b]Start game enabled:[/b] %s   •   [b]Script delay:[/b] %.2fs   •   [b]Script:[/b] %s" % [
		quest.editor_id, quest.form_id, ("  —  " + quest.full_name) if not quest.full_name.is_empty() else "",
		state.stage, _yes_no(state.running), _yes_no(state.completed), _yes_no(state.failed), _yes_no(quest == QuestServer.active_quest),
		quest.priority, _yes_no(quest.starts_enabled), QuestServer.get_script_delay(quest), script_name])
	var rows: PackedStringArray = ["[b]Objectives[/b]  [color=#7f848e](● displayed  ✔ completed)[/color]"]
	for objective in quest.objectives:
		rows.append("%s%s  [color=#e5c07b]%d[/color]  %s" % [
			"●" if state.objectives_displayed.has(objective.index) else "  ",
			"✔" if state.objectives_completed.has(objective.index) else "  ",
			objective.index, objective.text if not objective.text.is_empty() else "[color=#7f848e](no text)[/color]"])
	if quest.objectives.is_empty():
		rows.append("[color=#7f848e](none)[/color]")
	_set_text(_objectives, "\n".join(rows))
	rows = ["[b]Stages[/b]  [color=#7f848e](✔ done)[/color]"]
	for stage in quest.stages:
		var log_text := ""
		for entry in stage.log_entries:
			if not entry.log_text.is_empty():
				log_text = entry.log_text
				break
		rows.append("%s  [color=#e5c07b]%d[/color]  %s" % [
			"✔" if state.stages_done.has(stage.index) else "  ", stage.index, log_text.replace("\n", " ").left(160)])
	if quest.stages.is_empty():
		rows.append("[color=#7f848e](none)[/color]")
	_set_text(_stages, "\n".join(rows))


## Opens the quest's script in the Script Engine tab, creating its variables
## (at 0) if the script has not run yet.
func _open_script() -> void:
	if _selected == null or _selected.script_form_id == 0:
		return
	ScriptServer.get_quest_instance(_selected)
	var tabs := get_parent() as TabContainer
	var engine_tab := tabs.get_node_or_null("Scripting") if tabs != null else null
	if engine_tab == null:
		return
	tabs.current_tab = tabs.get_tab_idx_from_control(engine_tab)
	engine_tab.select_quest(_selected)


static func _yes_no(value: bool) -> String:
	return "[color=#98c379]yes[/color]" if value else "[color=#7f848e]no[/color]"
