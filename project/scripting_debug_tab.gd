extends Control

## Scene-authored runtime scripting workbench. It deliberately consumes the
## ScriptEngine debug API instead of reaching into private state, so the UI is
## an observer of the real VM rather than a second script-instance model.

@onready var _instances_list: ItemList = $Margin/VBox/VSplit/HSplit/Instances
@onready var _usage: RichTextLabel = $Margin/VBox/Usage
@onready var _details: RichTextLabel = $Margin/VBox/VSplit/HSplit/Right/Details
@onready var _locals: RichTextLabel = $Margin/VBox/VSplit/HSplit/Right/Locals
@onready var _source: CodeEdit = $Margin/VBox/VSplit/HSplit/Right/Source
@onready var _line: LineEdit = $Margin/VBox/ConsoleRow/Line
@onready var _run: Button = $Margin/VBox/ConsoleRow/Run
@onready var _clear: Button = $Margin/VBox/ConsoleRow.get_node_or_null("Clear")
@onready var _output: TextEdit = $Margin/VBox/VSplit/Output

var _engine: ScriptEngine
var _instances: Array = []
var _selected_node: Node = null

# Command history state
var _history: Array[String] = []
var _history_index: int = -1
var _current_input_buffer: String = ""

# Autocomplete candidates
var _builtin_candidates: Array[String] = [
	"ShowMessage", "GetButtonPressed", "PlaceAtMe", "CenterOnCell", "COC",
	"AddItem", "RemoveItem", "GetItemCount", "EquipItem", "UnequipItem",
	"Disable", "Enable", "GetDisabled", "Kill", "GetDead", "Resurrect",
	"SetOpenState", "GetOpenState", "PlayGroup", "SetHardcore", "GetHardcore",
	"MarkForDelete", "SetDestroyed", "GetDestroyed", "SetScale", "GetScale",
	"MoveTo", "PositionCell", "StopCombat", "StartCombat", "ResetHealth",
	"Player.Disable", "Player.Enable", "Player.AddItem", "Player.RemoveItem",
	"Player.PlaceAtMe", "Player.MoveTo", "Player.Kill", "Player.Resurrect",
	"Player.SetHardcore", "Set bInitialized to", "Set fTimer to", "Set iCount to"
]


func _ready() -> void:
	_engine = get_tree().root.get_node_or_null("Game/ScriptEngine") as ScriptEngine
	_source.editable = false
	_source.gutters_draw_line_numbers = true
	_output.editable = false

	_setup_highlighter()

	_run.pressed.connect(_run_line)
	if _clear:
		_clear.pressed.connect(func() -> void: _output.text = "")

	_line.text_submitted.connect(func(_text: String) -> void: _run_line())
	_line.gui_input.connect(_on_line_gui_input)

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


var _tab_matches: Array[String] = []
var _tab_match_index: int = 0
var _tab_token_start: int = 0
var _tab_prefix: String = ""


func _on_line_gui_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return

	var key_event := event as InputEventKey

	# Handle Tab completion (in-place, never steals focus)
	if key_event.keycode == KEY_TAB and not key_event.is_echo():
		_handle_tab_completion()
		accept_event()
		return

	# Any non-tab keystroke resets tab cycling
	if key_event.keycode != KEY_TAB:
		_tab_matches.clear()
		_tab_match_index = 0

	# Handle History navigation (Up / Down)
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
			accept_event()
			return


func _handle_tab_completion() -> void:
	var text := _line.text
	var caret := _line.caret_column

	# If already cycling through active matches on repeated Tab presses:
	if not _tab_matches.is_empty() and caret >= _tab_token_start:
		_tab_match_index = (_tab_match_index + 1) % _tab_matches.size()
		var chosen := _tab_matches[_tab_match_index]
		_apply_tab_completion(chosen)
		return

	# Extract token before caret
	var left_text := text.substr(0, caret)
	var token_start := maxi(left_text.rfind(" "), left_text.rfind("\t")) + 1
	var token := left_text.substr(token_start)

	if token.is_empty():
		return

	_tab_prefix = token.to_lower()
	_tab_token_start = token_start
	_tab_matches.clear()
	_tab_match_index = 0

	var candidates := _get_all_candidates()
	for c in candidates:
		if c.to_lower().begins_with(_tab_prefix):
			if not _tab_matches.has(c):
				_tab_matches.append(c)

	if _tab_matches.is_empty():
		for c in candidates:
			if c.to_lower().find(_tab_prefix) != -1:
				if not _tab_matches.has(c):
					_tab_matches.append(c)

	if _tab_matches.is_empty():
		return

	_apply_tab_completion(_tab_matches[0])


func _apply_tab_completion(completed_word: String) -> void:
	var right_text := _line.text.substr(_line.caret_column)
	var prefix_text := _line.text.substr(0, _tab_token_start)
	var suffix := " " if right_text.is_empty() or not right_text.begins_with(" ") else ""

	_line.text = prefix_text + completed_word + suffix + right_text
	_line.caret_column = (prefix_text + completed_word + suffix).length()


func _get_all_candidates() -> Array[String]:
	var candidates: Array[String] = _builtin_candidates.duplicate()
	for entry in _instances:
		var node_name := String(entry.get("node_name", ""))
		var script_name := String(entry.get("script_name", ""))
		var form_hex := "0x%X" % int(entry.get("script_form_id", 0))
		if not node_name.is_empty() and not candidates.has(node_name):
			candidates.append(node_name)
		if not script_name.is_empty() and not candidates.has(script_name):
			candidates.append(script_name)
		if not candidates.has(form_hex):
			candidates.append(form_hex)
	return candidates


func _process(_delta: float) -> void:
	if is_visible_in_tree():
		_refresh()


func _refresh() -> void:
	if _engine == null:
		_usage.text = "ScriptEngine not found"
		return
	var previous := _selected_node
	_instances = _engine.get_debug_instances()
	_instances_list.clear()
	for entry in _instances:
		_instances_list.add_item("%s  —  %s" % [entry["node_name"], entry["script_name"]])
		if entry["node"] == previous:
			_instances_list.select(_instances_list.item_count - 1)
	var usage: Dictionary = _engine.get_debug_usage()
	_usage.text = "[color=#61afef]●[/color] [b]%d[/b] live context(s)   •   [color=#98c379]●[/color] [b]%d[/b] cached script(s)   •   [color=#e5c07b]●[/color] [b]%d[/b] local slot(s) ([color=#e5c07b]%d[/color] non-zero)" % [
		usage["contexts"], usage["cached_scripts"], usage["local_slots"], usage["non_zero_locals"]
	]
	if previous != null and not is_instance_valid(previous):
		_selected_node = null
		_show_selected()


func _select_instance(index: int) -> void:
	if index < 0 or index >= _instances.size():
		return
	_selected_node = _instances[index]["node"]
	_show_selected()


func _show_selected() -> void:
	if _selected_node == null:
		_details.text = "[color=#7f848e]Select a live scripted reference. Console commands run with player as caller if none selected.[/color]"
		_locals.text = ""
		_source.text = ""
		return
	for entry in _instances:
		if entry["node"] != _selected_node:
			continue
		var block_badges: PackedStringArray = []
		for b in entry.get("blocks", []):
			block_badges.append("[color=#61afef][%s][/color]" % b)
		_details.text = "[b]📜 %s[/b] [color=#98c379](0x%08X)[/color]   •   [b]Node:[/b] [color=#e5c07b]%s[/color]   •   [b]Blocks:[/b] %s" % [
			entry["script_name"], int(entry["script_form_id"]),
			entry["node_name"], " ".join(block_badges) if not block_badges.is_empty() else "[color=#7f848e](none)[/color]"
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

	var reply: Dictionary = _engine.run_debug_line(cmd, _selected_node)
	_output.text += "> " + cmd + "\n" + ("OK" if bool(reply.get("ok", false)) else "ERROR") + ": " + String(reply.get("message", ""))
	if reply.has("result"):
		_output.text += ": " + str(reply["result"])
	_output.text += "\n"
	_output.scroll_vertical = _output.get_line_count()
	_line.clear()
	_refresh()
