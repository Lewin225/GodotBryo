extends Control

## Scene-authored runtime scripting workbench.  It deliberately consumes the
## ScriptEngine debug API instead of reaching into private state, so the UI is
## an observer of the real VM rather than a second script-instance model.

@onready var _instances_list: ItemList = $Margin/VBox/VSplit/HSplit/Instances
@onready var _usage: Label = $Margin/VBox/Usage
@onready var _details: Label = $Margin/VBox/VSplit/HSplit/Right/Details
@onready var _locals: RichTextLabel = $Margin/VBox/VSplit/HSplit/Right/Locals
@onready var _source: CodeEdit = $Margin/VBox/VSplit/HSplit/Right/Source
@onready var _line: LineEdit = $Margin/VBox/ConsoleRow/Line
@onready var _run: Button = $Margin/VBox/ConsoleRow/Run
@onready var _output: TextEdit = $Margin/VBox/VSplit/Output

var _engine: ScriptEngine
var _instances: Array = []
var _selected_node: Node = null

func _ready() -> void:
	_engine = get_tree().root.get_node_or_null("Game/ScriptEngine") as ScriptEngine
	_source.editable = false
	_source.gutters_draw_line_numbers = true
	_output.editable = false
	_run.pressed.connect(_run_line)
	_line.text_submitted.connect(func(_text: String) -> void: _run_line())
	_instances_list.item_selected.connect(_select_instance)
	_refresh()

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
	_usage.text = "%d live context(s), %d cached script(s), %d local slot(s), %d non-zero" % [usage["contexts"], usage["cached_scripts"], usage["local_slots"], usage["non_zero_locals"]]
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
		_details.text = "Select a live scripted reference. Console commands otherwise run with player as caller."
		_locals.text = ""
		_source.text = ""
		return
	for entry in _instances:
		if entry["node"] != _selected_node:
			continue
		_details.text = "%s  |  script 0x%X  |  blocks: %s" % [entry["script_name"], entry["script_form_id"], ", ".join(entry["blocks"])]
		var local_lines: PackedStringArray = []
		for local_name in entry["locals"]:
			local_lines.append("%s = %s" % [local_name, str(entry["locals"][local_name])])
		_locals.text = "[b]Local storage[/b]\n" + "\n".join(local_lines) if not local_lines.is_empty() else "[b]Local storage[/b]\n(no declared locals)"
		_source.text = entry["source_text"]
		return

func _run_line() -> void:
	if _engine == null:
		return
	var reply: Dictionary = _engine.run_debug_line(_line.text, _selected_node)
	_output.text += "> " + _line.text + "\n" + ("OK" if bool(reply.get("ok", false)) else "ERROR") + ": " + String(reply.get("message", ""))
	if reply.has("result"):
		_output.text += ": " + str(reply["result"])
	_output.text += "\n"
	_line.clear()
	_refresh()
