extends Control

## Scene-authored script inspector. Reads ScriptServer's debug API (instances,
## usage) rather than its internal state. Script lines run in the console
## (ConsoleOverlay, `), not here; Target in Console makes the selected
## reference the console's target.

@onready var _instances_list: ItemList = $Margin/VBox/HSplit/Left/Instances
@onready var _filter: LineEdit = $Margin/VBox/HSplit/Left/LineEdit
@onready var _usage: RichTextLabel = $Margin/VBox/Usage
@onready var _details: RichTextLabel = $Margin/VBox/HSplit/Right/Details
@onready var _console_target: Button = $Margin/VBox/HSplit/Right/ConsoleTarget
@onready var _locals: RichTextLabel = $Margin/VBox/HSplit/Right/ScrollContainer/Locals
@onready var _source: CodeEdit = $Margin/VBox/HSplit/Right/Source

var _engine: Node
var _instances: Array = []
var _filtered_instances: Array = []
var _selected_reference: EsmReference = null
## The selected entry's reference or, for a quest script, its QuestBase.
var _selected_key: Object = null

## The instance list rebuilds at most this often while the tab is shown: with
## hundreds of script instances a rebuild every frame costs ~10 ms.
const REFRESH_INTERVAL_SEC := 0.25
var _refresh_timer := 0.0

func _ready() -> void:
	_engine = get_tree().root.get_node_or_null("ScriptServer")
	_source.editable = false
	_source.gutters_draw_line_numbers = true

	_setup_highlighter()

	_console_target.pressed.connect(_target_in_console)

	_filter.clear_button_enabled = true
	_filter.text_changed.connect(func(_new_text: String) -> void: _refresh())

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


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_refresh_timer -= delta
	if _refresh_timer > 0.0:
		return
	_refresh_timer = REFRESH_INTERVAL_SEC
	_refresh()


func _refresh() -> void:
	if _engine == null:
		_usage.text = "ScriptServer not found"
		return
	_instances = _engine.get_debug_instances()
	_filtered_instances.clear()
	_instances_list.clear()
	var needle := _filter.text.strip_edges().to_lower()
	var raw_hex := needle.trim_prefix("0x")
	for entry in _instances:
		if not needle.is_empty():
			var name_str := String(entry.get("name", "")).to_lower()
			var script_str := String(entry.get("script_name", "")).to_lower()
			var quest: EsmBase = entry.get("quest") as EsmBase
			var ref: EsmReference = entry.get("reference") as EsmReference
			var id_match := (
				_matches_form_id(int(entry.get("script_form_id", 0)), needle, raw_hex)
				or (quest != null and _matches_form_id(quest.form_id, needle, raw_hex))
				or (ref != null and _matches_form_id(ref.base_form_id, needle, raw_hex))
			)
			if not name_str.contains(needle) and not script_str.contains(needle) and not id_match:
				continue
		_filtered_instances.append(entry)
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
	if index < 0 or index >= _filtered_instances.size():
		return
	var entry: Dictionary = _filtered_instances[index]
	_selected_key = _entry_key(entry)
	_selected_reference = entry["reference"]
	_show_selected()


## Selects a quest's script, as the Quests tab's Show Script does.
func select_quest(quest: QuestBase) -> void:
	_selected_key = quest
	_selected_reference = null
	_filter.text = ""
	_refresh()
	_show_selected()


## An entry's identity: its reference, or its quest for a quest script.
static func _entry_key(entry: Dictionary) -> Object:
	return entry["reference"] if entry["reference"] != null else entry["quest"]


## Whether a FormID's 8-digit hex contains the filter text: `raw_hex` is the
## filter without its `0x` prefix, `needle` the whole filter. 0 never matches.
static func _matches_form_id(form_id: int, needle: String, raw_hex: String) -> bool:
	if form_id == 0:
		return false
	var hex_str := "%08x" % form_id
	return (not raw_hex.is_empty() and hex_str.contains(raw_hex)) or ("0x" + hex_str).contains(needle)


func _show_selected() -> void:
	_console_target.disabled = _selected_reference == null
	if _selected_key == null:
		_details.text = "[color=#7f848e]Select a scripted reference or quest.[/color]"
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


## Opens the console with the selected reference as its target.
func _target_in_console() -> void:
	var console := get_tree().get_first_node_in_group(&"console") as ConsoleOverlay
	if console != null and _selected_reference != null:
		console.target_reference(_selected_reference)
