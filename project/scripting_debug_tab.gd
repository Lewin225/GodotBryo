extends Control

## Scene-authored runtime scripting workbench. It deliberately consumes the
## ScriptEngine debug API instead of reaching into private state, so the UI is
## an observer of the real VM rather than a second script-instance model.

@onready var _instances_list: ItemList = $Margin/VBox/VSplit/HSplit/Instances
@onready var _usage: Label = $Margin/VBox/Usage
@onready var _details: Label = $Margin/VBox/VSplit/HSplit/Right/Details
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

# Autocomplete state
var _suggestions_popup: PopupMenu
var _suggestions: Array[String] = []
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
	_setup_suggestions_popup()

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


func _setup_suggestions_popup() -> void:
	_suggestions_popup = PopupMenu.new()
	_suggestions_popup.unfocusable = true
	_suggestions_popup.id_pressed.connect(_on_suggestion_selected)
	add_child(_suggestions_popup)


func _on_line_gui_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return

	var key_event := event as InputEventKey

	# Handle suggestions popup navigation
	if _suggestions_popup.visible:
		if key_event.keycode == KEY_ESCAPE:
			_suggestions_popup.hide()
			accept_event()
			return
		elif key_event.keycode == KEY_DOWN:
			var next_idx: int = (_suggestions_popup.get_focused_item() + 1) % maxi(1, _suggestions_popup.item_count)
			_suggestions_popup.set_focused_item(next_idx)
			accept_event()
			return
		elif key_event.keycode == KEY_UP:
			var prev_idx: int = (_suggestions_popup.get_focused_item() - 1 + _suggestions_popup.item_count) % maxi(1, _suggestions_popup.item_count)
			_suggestions_popup.set_focused_item(prev_idx)
			accept_event()
			return
		elif key_event.keycode == KEY_TAB or key_event.keycode == KEY_ENTER or key_event.keycode == KEY_KP_ENTER:
			var focused := _suggestions_popup.get_focused_item()
			if focused >= 0 and focused < _suggestions.size():
				_on_suggestion_selected(focused)
				accept_event()
				return

	# Handle Tab completion when popup isn't visible
	if key_event.keycode == KEY_TAB and not key_event.is_echo():
		_show_suggestions(true)
		if not _suggestions.is_empty():
			accept_event()
			return

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


func _on_line_text_changed(new_text: String) -> void:
	if new_text.strip_edges().is_empty():
		_suggestions_popup.hide()
		return
	_show_suggestions(false)


func _show_suggestions(force: bool) -> void:
	var text := _line.text
	var lower_text := text.to_lower().strip_edges()
	if not force and lower_text.length() < 2:
		_suggestions_popup.hide()
		return

	# Build candidate list
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

	# Filter matches
	_suggestions.clear()
	for c in candidates:
		if c.to_lower().find(lower_text) != -1 or lower_text.is_empty():
			_suggestions.append(c)
			if _suggestions.size() >= 10:
				break

	if _suggestions.is_empty():
		_suggestions_popup.hide()
		return

	_suggestions_popup.clear()
	for i in _suggestions.size():
		_suggestions_popup.add_item(_suggestions[i], i)

	# Position popup below LineEdit
	var global_pos := _line.get_screen_position()
	var popup_size := Vector2i(maxi(int(_line.size.x), 260), mini(_suggestions.size() * 28 + 10, 220))
	_suggestions_popup.position = Vector2i(int(global_pos.x), int(global_pos.y + _line.size.y + 4.0))
	_suggestions_popup.size = popup_size
	_suggestions_popup.reset_size()
	_suggestions_popup.show()
	_suggestions_popup.set_focused_item(0)


func _on_suggestion_selected(id: int) -> void:
	if id >= 0 and id < _suggestions.size():
		_line.text = _suggestions[id]
		_line.caret_column = _line.text.length()
	_suggestions_popup.hide()
	_line.grab_focus()


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
	_usage.text = "%d live context(s), %d cached script(s), %d local slot(s), %d non-zero" % [
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
		_details.text = "Select a live scripted reference. Console commands run with player as caller if none selected."
		_locals.text = ""
		_source.text = ""
		return
	for entry in _instances:
		if entry["node"] != _selected_node:
			continue
		var block_badges: PackedStringArray = []
		for b in entry.get("blocks", []):
			block_badges.append("[%s]" % b)
		_details.text = "📜 %s (0x%X)   •   Node: %s   •   Blocks: %s" % [
			entry["script_name"], entry["script_form_id"],
			entry["node_name"], " ".join(block_badges) if not block_badges.is_empty() else "(none)"
		]

		var locals_dict: Dictionary = entry.get("locals", {})
		if locals_dict.is_empty():
			_locals.text = "[b]Local Storage:[/b]  (no declared locals)"
		else:
			var rows: PackedStringArray = []
			rows.append("[table=3]")
			rows.append("[cell][b]Variable[/b][/cell][cell][b]Type[/b][/cell][cell][b]Value[/b][/cell]")
			for var_name in locals_dict:
				var val: Variant = locals_dict[var_name]
				var type_name := "int" if val is int else ("float" if val is float else "string")
				rows.append("[cell]%s[/cell][cell]%s[/cell][cell][color=#e5c07b]%s[/color][/cell]" % [
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
	_suggestions_popup.hide()

	var reply: Dictionary = _engine.run_debug_line(cmd, _selected_node)
	_output.text += "> " + cmd + "\n" + ("OK" if bool(reply.get("ok", false)) else "ERROR") + ": " + String(reply.get("message", ""))
	if reply.has("result"):
		_output.text += ": " + str(reply["result"])
	_output.text += "\n"
	_output.scroll_vertical = _output.get_line_count()
	_line.clear()
	_refresh()
