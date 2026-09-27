extends Control

## Scene-authored runtime scripting workbench. Reads ScriptServer's debug API
## (instances, usage, console) rather than its internal state.

@onready var _instances_list: ItemList = $Margin/VBox/VSplit/HSplit/Instances
@onready var _usage: RichTextLabel = $Margin/VBox/Usage
@onready var _details: RichTextLabel = $Margin/VBox/VSplit/HSplit/Right/Details
@onready var _locals: RichTextLabel = $Margin/VBox/VSplit/HSplit/Right/Locals
@onready var _source: CodeEdit = $Margin/VBox/VSplit/HSplit/Right/Source
@onready var _line: LineEdit = $Margin/VBox/ConsoleRow/Line
@onready var _run: Button = $Margin/VBox/ConsoleRow/Run
@onready var _clear: Button = $Margin/VBox/ConsoleRow.get_node_or_null("Clear")
@onready var _output: TextEdit = $Margin/VBox/VSplit/Output
@onready var _suggestions_panel: PanelContainer = get_node_or_null("SuggestionsPanel")
@onready var _suggestions_list: RichTextLabel = get_node_or_null("SuggestionsPanel/Margin/SuggestionsList")

var _engine: Node
var _instances: Array = []
var _selected_reference: EsmReference = null
## The selected entry's reference or, for a quest script, its QuestBase.
var _selected_key: Object = null

# Command history state
var _history: Array[String] = []
var _history_index: int = -1
var _current_input_buffer: String = ""

# Autocomplete state
var _suggestions: Array[String] = []
var _suggestion_index: int = 0
var _token_start: int = 0
var _token_prefix: String = ""
var _navigating_suggestions: bool = false


func _ready() -> void:
	_engine = get_tree().root.get_node_or_null("ScriptServer")
	_source.editable = false
	_source.gutters_draw_line_numbers = true
	_output.editable = false

	_setup_highlighter()

	if _suggestions_panel != null:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color("#1e2227")
		sb.border_color = Color("#4b5263")
		sb.set_border_width_all(1)
		sb.set_corner_radius_all(4)
		sb.shadow_color = Color(0, 0, 0, 0.45)
		sb.shadow_size = 8
		sb.shadow_offset = Vector2(0, 4)
		_suggestions_panel.add_theme_stylebox_override("panel", sb)
		_suggestions_panel.hide()

	_run.pressed.connect(_run_line)
	if _clear:
		_clear.pressed.connect(func() -> void: _output.text = "")

	_line.text_submitted.connect(func(_text: String) -> void: _run_line())
	_line.gui_input.connect(_on_line_gui_input)
	_line.text_changed.connect(_on_line_text_changed)

	_instances_list.item_selected.connect(_select_instance)
	_refresh()


func _setup_highlighter() -> void:
	var hl := CodeHighlighter.new()
	hl.number_color = Color("#d19a66")
	hl.symbol_color = Color("#c678dd")
	hl.member_variable_color = Color("#e5c07b")
	hl.function_color = Color("#61afef")

	# Comments and strings
	hl.add_color_region(";", "", Color("#7f848e"), true)
	hl.add_color_region("\"", "\"", Color("#98c379"), false)

	# GECK keywords
	var keywords := [
		"scn", "scriptname", "begin", "end", "if", "else", "elseif", "endif",
		"set", "to", "return", "print", "let", "short", "long", "int", "float",
		"ref", "string_var", "array_var", "GameMode", "OnActivate", "OnLoad",
		"OnEquip", "OnPackageDone", "Menumode", "OnReset", "OnTriggerEnter",
		"OnTriggerLeave", "OnDeath", "OnMurder", "OnHit", "OnHitWith"
	]
	for kw in keywords:
		hl.add_keyword_color(kw, Color("#c678dd"))

	_source.syntax_highlighter = hl


func _on_line_text_changed(_new_text: String) -> void:
	_update_suggestions_panel()


func _update_suggestions_panel() -> void:
	if _suggestions_panel == null:
		return

	var text := _line.text
	var caret := _line.caret_column
	var left_text := text.substr(0, caret)

	if left_text.strip_edges().is_empty():
		_suggestions.clear()
		_suggestion_index = 0
		_navigating_suggestions = false
		_suggestions_panel.hide()
		return

	var token_start := maxi(left_text.rfind(" "), left_text.rfind("\t")) + 1
	var token := left_text.substr(token_start)
	_token_start = token_start
	_token_prefix = token.to_lower().strip_edges()
	_suggestions.clear()

	var candidates := _get_contextual_candidates(left_text)

	# 1. Prefix matches
	if not _token_prefix.is_empty():
		for c in candidates:
			if c.to_lower().begins_with(_token_prefix):
				if not _suggestions.has(c):
					_suggestions.append(c)
					if _suggestions.size() >= 8:
						break

	# 2. Substring matches if under 8
	if _suggestions.size() < 8 and not _token_prefix.is_empty():
		for c in candidates:
			if not _suggestions.has(c) and c.to_lower().find(_token_prefix) != -1:
				_suggestions.append(c)
				if _suggestions.size() >= 8:
					break

	# 3. If token is empty (just typed command + space, e.g. "coc "): show top candidates
	if _token_prefix.is_empty():
		for c in candidates:
			if not _suggestions.has(c):
				_suggestions.append(c)
				if _suggestions.size() >= 8:
					break

	# If exact single match is already typed and nothing else matches
	if _suggestions.is_empty() or (_suggestions.size() == 1 and _suggestions[0].to_lower() == _token_prefix):
		_suggestions.clear()
		_suggestion_index = 0
		_navigating_suggestions = false
		_suggestions_panel.hide()
		return

	if _suggestion_index >= _suggestions.size():
		_suggestion_index = 0

	_render_suggestions_panel()


func _render_suggestions_panel() -> void:
	if _suggestions_panel == null or _suggestions.is_empty():
		if _suggestions_panel != null:
			_suggestions_panel.hide()
		return

	var rows: PackedStringArray = []
	for i in _suggestions.size():
		var c := _suggestions[i]
		if _navigating_suggestions and i == _suggestion_index:
			rows.append("[color=#61afef][b]▶  %s[/b][/color]" % c)
		else:
			rows.append("[color=#abb2bf]    %s[/color]" % c)

	rows.append("[color=#5c6370][font_size=11]↑/↓ to select  •  Tab/Enter to apply  •  Esc to dismiss[/font_size][/color]")
	if _suggestions_list != null:
		_suggestions_list.text = "\n".join(rows)

	# Position floating panel directly below _line without affecting the flow of the UI
	var line_pos := _line.global_position
	var line_size := _line.size
	_suggestions_panel.global_position = Vector2(line_pos.x, line_pos.y + line_size.y + 4.0)
	_suggestions_panel.custom_minimum_size = Vector2(maxf(line_size.x, 260.0), 0)
	_suggestions_panel.reset_size()
	_suggestions_panel.show()


func _on_line_gui_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return

	var key_event := event as InputEventKey

	# Handle interactive suggestion navigation when suggestions panel is visible
	if _suggestions_panel != null and _suggestions_panel.visible and not _suggestions.is_empty():
		if key_event.keycode == KEY_DOWN and not key_event.is_echo():
			if not _navigating_suggestions:
				_navigating_suggestions = true
				_suggestion_index = 0
			else:
				_suggestion_index = (_suggestion_index + 1) % _suggestions.size()
			_render_suggestions_panel()
			accept_event()
			return
		elif key_event.keycode == KEY_UP and not key_event.is_echo():
			if not _navigating_suggestions:
				_navigating_suggestions = true
				_suggestion_index = _suggestions.size() - 1
			else:
				_suggestion_index = (_suggestion_index - 1 + _suggestions.size()) % _suggestions.size()
			_render_suggestions_panel()
			accept_event()
			return
		elif key_event.keycode == KEY_TAB and not key_event.is_echo():
			_apply_selected_suggestion()
			accept_event()
			return
		elif (key_event.keycode == KEY_ENTER or key_event.keycode == KEY_KP_ENTER) and not key_event.is_echo():
			if _navigating_suggestions:
				_apply_selected_suggestion()
				accept_event()
				return
		elif key_event.keycode == KEY_ESCAPE and not key_event.is_echo():
			_suggestions.clear()
			_navigating_suggestions = false
			_suggestions_panel.hide()
			accept_event()
			return

	# Handle History navigation (Up / Down) when not navigating suggestions
	if key_event.keycode == KEY_UP and not key_event.is_echo():
		if _history.is_empty():
			return
		if _history_index == -1:
			_current_input_buffer = _line.text
			_history_index = _history.size() - 1
		elif _history_index > 0:
			_history_index -= 1
		_line.text = _history[_history_index]
		_line.caret_column = _line.text.length()
		_update_suggestions_panel()
		accept_event()
		return
	elif key_event.keycode == KEY_DOWN and not key_event.is_echo():
		if _history_index != -1:
			if _history_index < _history.size() - 1:
				_history_index += 1
				_line.text = _history[_history_index]
			else:
				_history_index = -1
				_line.text = _current_input_buffer
			_line.caret_column = _line.text.length()
			_update_suggestions_panel()
			accept_event()
			return
	elif key_event.keycode == KEY_TAB and not key_event.is_echo():
		_handle_tab_completion()
		accept_event()
		return


func _apply_selected_suggestion() -> void:
	if _suggestions.is_empty():
		return
	var chosen_idx := clampi(_suggestion_index, 0, _suggestions.size() - 1)
	var completed_word := _suggestions[chosen_idx]

	var right_text := _line.text.substr(_line.caret_column)
	var prefix_text := _line.text.substr(0, _token_start)
	var suffix := " " if right_text.is_empty() or not right_text.begins_with(" ") else ""

	_line.text = prefix_text + completed_word + suffix + right_text
	_line.caret_column = (prefix_text + completed_word + suffix).length()

	_suggestions.clear()
	_navigating_suggestions = false
	if _suggestions_panel != null:
		_suggestions_panel.hide()


func _handle_tab_completion() -> void:
	_update_suggestions_panel()
	if not _suggestions.is_empty():
		_apply_selected_suggestion()


func _get_contextual_candidates(left_text: String) -> Array[String]:
	var game_node: Node = get_tree().root.get_node_or_null("Game") if is_inside_tree() else null
	return ScriptCandidateProvider.get_contextual_candidates(
		left_text, _engine, _selected_reference, _instances, game_node
	)


func _process(_delta: float) -> void:
	if is_visible_in_tree():
		_refresh()


func _refresh() -> void:
	if _engine == null:
		_usage.text = "ScriptServer not found"
		return
	_instances = _engine.get_debug_instances()
	_instances_list.clear()
	for entry in _instances:
		var state := ""
		if entry["quest"] != null:
			state = "  (quest)" if entry["loaded"] else "  (quest, stopped)"
		elif not entry["loaded"]:
			state = "  (unloaded)"
		_instances_list.add_item("%s  —  %s%s" % [entry["name"], entry["script_name"], state])
		if _entry_key(entry) == _selected_key and _selected_key != null:
			_instances_list.select(_instances_list.item_count - 1)
	var usage: Dictionary = _engine.get_debug_usage()
	_usage.text = "[color=#61afef]●[/color] [b]%d[/b] script instance(s) ([b]%d[/b] loaded)   •   [color=#98c379]●[/color] [b]%d[/b] cached script(s)   •   [color=#e5c07b]●[/color] [b]%d[/b] local slot(s) ([color=#e5c07b]%d[/color] non-zero)" % [
		usage["instances"], usage["loaded"], usage["cached_scripts"], usage["local_slots"], usage["non_zero_locals"]
	]


func _select_instance(index: int) -> void:
	if index < 0 or index >= _instances.size():
		return
	_selected_key = _entry_key(_instances[index])
	_selected_reference = _instances[index]["reference"]
	_show_selected()


## Selects a quest's script, as the Quests tab's Show Script does.
func select_quest(quest: QuestBase) -> void:
	_selected_key = quest
	_selected_reference = null
	_refresh()
	_show_selected()


## An entry's identity: its reference, or its quest for a quest script.
static func _entry_key(entry: Dictionary) -> Object:
	return entry["reference"] if entry["reference"] != null else entry["quest"]


func _show_selected() -> void:
	if _selected_key == null:
		_details.text = "[color=#7f848e]Select a scripted reference or quest. Console commands run with no calling reference unless a reference is selected.[/color]"
		_locals.text = ""
		_source.text = ""
		return
	for entry in _instances:
		if _entry_key(entry) != _selected_key:
			continue
		var block_badges: PackedStringArray = []
		for b in entry.get("blocks", []):
			block_badges.append("[color=#61afef][%s][/color]" % b)
		_details.text = "[b]📜 %s[/b] [color=#98c379](0x%08X)[/color]   •   [b]%s:[/b] [color=#e5c07b]%s[/color]   •   [b]Blocks:[/b] %s" % [
			entry["script_name"], int(entry["script_form_id"]),
			"Quest" if entry["quest"] != null else "Reference", entry["name"], " ".join(block_badges) if not block_badges.is_empty() else "[color=#7f848e](none)[/color]"
		]

		var locals_dict: Dictionary = entry.get("locals", {})
		if locals_dict.is_empty():
			_locals.text = "[b]Local Storage:[/b]  [color=#7f848e](no declared locals)[/color]"
		else:
			var rows: PackedStringArray = []
			rows.append("[table=3]")
			rows.append("[cell][b]Variable[/b]  [/cell][cell][b]Type[/b]  [/cell][cell][b]Value[/b][/cell]")
			for var_name in locals_dict:
				var val: Variant = locals_dict[var_name]
				var type_name := "int" if val is int else ("float" if val is float else "string")
				rows.append("[cell][color=#e5c07b]%s[/color]  [/cell][cell][color=#c678dd]%s[/color]  [/cell][cell][color=#98c379]%s[/color][/cell]" % [
					var_name, type_name, str(val)
				])
			rows.append("[/table]")
			_locals.text = "[b]Local Storage:[/b]\n" + "".join(rows)

		_source.text = entry.get("source_text", "")
		return


func _run_line() -> void:
	if _engine == null:
		return
	var cmd := _line.text.strip_edges()
	if cmd.is_empty():
		return

	# Record history
	if _history.is_empty() or _history.back() != cmd:
		_history.append(cmd)
	_history_index = -1
	_current_input_buffer = ""

	var reply: Dictionary = _engine.run_debug_line(cmd, _selected_reference)
	_output.text += "> " + cmd + "\n" + ("OK" if bool(reply.get("ok", false)) else "ERROR") + ": " + String(reply.get("message", ""))
	if reply.has("result"):
		_output.text += ": " + str(reply["result"])
	_output.text += "\n"
	_output.scroll_vertical = _output.get_line_count()
	_line.clear()
	_refresh()
