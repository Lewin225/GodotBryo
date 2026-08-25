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
@onready var _suggestions_panel: PanelContainer = get_node_or_null("SuggestionsPanel")
@onready var _suggestions_list: RichTextLabel = get_node_or_null("SuggestionsPanel/Margin/SuggestionsList")

var _engine: ScriptEngine
var _instances: Array = []
var _selected_node: Node = null

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

const CELL_CANDIDATES: Array[String] = [
	"GSDocMitchellHouse", "GoodspringsGasStation", "GoodspringsSaloon", "GoodspringsSchoolhouse",
	"GoodspringsGeneralStore", "GoodspringsVictorShack", "GoodspringsCave", "GoodspringsHome01",
	"GoodspringsHome02", "GoodspringsHome03", "GoodspringsAbandonedShack",
	"VikkiAndVanceCasino", "BisonSteveHotel01", "BisonSteveHotel02", "PrimmSheriffOffice",
	"MojaveExpressNashResidence", "PrimmBeagleHouse", "MojaveOutpostHQ", "MojaveOutpostBarracks",
	"NCRCFAdministration01", "NCRCFCellBlockA", "NCRCFCellBlockB",
	"NovacDinoBiteGiftShop", "NovacPlayerRoom", "NovacFrontDesk", "NovacJeannieMayHouse",
	"NovacNoBarksShack", "NovacBoonesRoom", "NovacMannyRoom", "NovacRangerAndyHome",
	"GibsonScrapYardGarage", "BigHornSaloon", "BoulderCityTrainStation",
	"TheTopsCasino", "TheTopsRestaurant", "TheTopsTheater", "TheTops13thFloor", "TheTopsPresSuite",
	"UltraLuxeCasino", "UltraLuxePenthouse", "UltraLuxeGourmand", "UltraLuxeBathhouse",
	"GomorrahMain", "GomorrahBrimstone", "GomorrahClubSuites", "Lucky38Casino", "Lucky38Penthouse",
	"Lucky38PresSuite", "Lucky38ControlRoom", "Vault21GiftShop", "Vault21", "MichaelAngeloWorkshop",
	"NCREmbassy", "AtomicWranglerCasino", "KingsSchoolOfImpersonation", "MickAndRalphs", "SilverRush",
	"OldMormonFortMormonFort", "CeruleanRobotics", "MiguelsPawnShop", "CasaMadridApartments", "TheThorn",
	"Vault3a", "Vault3b", "Vault11a", "Vault11b", "Vault19a", "Vault22a", "Vault22Common", "Vault34a", "Vault34Armory",
	"McCarranConcourse", "McCarranTerminal", "CampGolfHouseResort", "CampForlornHopeCommand",
	"HooverDamVisitorCenter", "HooverDamPowerPlant01", "HooverDamOffices", "HELIOSOnePlant", "HELIOSOneTower",
	"REPCONNHQ01", "REPCONNTestFacility", "REPCONNBasement", "SunsetSarsaparillaHQ", "GunRunnersHQ",
	"JacobstownLodge", "BlackMountainRadioStation", "HiddenValleyBunkerL1", "NellisBoomerHangar", "NellisMuseum",
	"GreatKhanLonghouse", "LegatesTent", "DevArmory", "TestMentats", "TestJoshWeapons", "TestTraps", "Endgame"
]

const ITEM_CANDIDATES: Array[String] = [
	"Caps001", "0x0000000F", "BobbyPin", "PreWarMoney", "NCRMoney", "LegionMoney", "REPCONNKeycard", "0x000E2C80",
	"Stimpak", "0x00004334", "SuperStimpak", "DoctorBag", "0x00004332", "RadAway", "0x00004342", "RadX", "0x00004340",
	"MedX", "Buffout", "Mentats", "Psycho", "Jet", "PurifiedWater", "SunsetSarsaparilla", "NukaCola",
	"WeapNV9mmPistol", "WeapNV9mmSMG", "0x001465A6", "WeapNVServiceRifle", "0x000E377A", "WeapNVHuntingRifle",
	"WeapNVDynamite", "0x000E3778", "WeapNVFragGrenade", "WeapNVLaserRifle", "WeapNVPlasmaPistol", "WeapNVSuperSledge",
	"Ammo9mm", "Ammo556mm", "Ammo308", "Ammo10mm", "Ammo12Gauge", "Ammo20Gauge", "AmmoEnergyCell", "AmmoMicroFusionCell"
]

const MESSAGE_CANDIDATES: Array[String] = [
	"GSBrokenSMGMsg", "GenericDoorLocked", "VMS03Msg01", "VMS03Msg02"
]

var _builtin_candidates: Array[String] = [
	"ShowMessage", "GetButtonPressed", "PlaceAtMe", "CenterOnCell", "COC",
	"AddItem", "RemoveItem", "GetItemCount", "EquipItem", "UnequipItem",
	"Disable", "Enable", "GetDisabled", "Kill", "GetDead", "Resurrect",
	"SetOpenState", "GetOpenState", "PlayGroup", "SetHardcore", "GetHardcore",
	"MarkForDelete", "SetDestroyed", "GetDestroyed", "SetScale", "GetScale",
	"MoveTo", "PositionCell", "StopCombat", "StartCombat", "ResetHealth",
	"tcl", "TCL", "ToggleCollision",
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
	var trimmed := left_text.lstrip(" \t")
	var ends_with_space := left_text.ends_with(" ") or left_text.ends_with("\t")
	var tokens := trimmed.split(" ", false)

	if tokens.is_empty():
		return _get_command_candidates()

	var cmd := tokens[0].to_lower()
	var arg_idx: int = tokens.size() - 1
	if ends_with_space:
		arg_idx += 1

	if arg_idx == 0:
		return _get_command_candidates()

	if arg_idx == 1:
		match cmd:
			"coc", "centeroncell":
				return _get_cell_candidates()
			"showmessage":
				return _get_message_candidates()
			"additem", "removeitem", "player.additem", "player.removeitem", "equipitem", "unequipitem", "getitemcount":
				return _get_item_candidates()
			"placeatme", "player.placeatme":
				return _get_placeable_candidates()
			"playgroup":
				return ["Forward", "Backward", "Left", "Right", "Idle", "Attack", "Equip", "Unequip", "SpecialIdle"]
			"setopenstate", "setdestroyed", "sethardcore", "player.sethardcore":
				return ["0", "1"]
			"set", "player.set":
				return _get_variable_candidates()
			"kill", "resurrect", "enable", "disable", "getdisabled", "getdead":
				return _get_reference_candidates()

	if arg_idx == 2:
		match cmd:
			"additem", "removeitem", "player.additem", "player.removeitem":
				return ["1", "5", "10", "25", "50", "100"]
			"set", "player.set":
				return ["to"]
			"placeatme", "player.placeatme":
				return ["1", "0,0,0"]

	return _get_command_candidates()


func _get_cell_candidates() -> Array[String]:
	return CELL_CANDIDATES.duplicate()


func _get_item_candidates() -> Array[String]:
	return ITEM_CANDIDATES.duplicate()


func _get_message_candidates() -> Array[String]:
	return MESSAGE_CANDIDATES.duplicate()


func _get_placeable_candidates() -> Array[String]:
	var list: Array[String] = ITEM_CANDIDATES.duplicate()
	for c in ["GSDocMitchellDoor", "GSRadio", "Caps001", "WeapNVDynamite", "Stimpak"]:
		if not list.has(c):
			list.append(c)
	return list


func _get_variable_candidates() -> Array[String]:
	var list: Array[String] = ["bInitialized", "fTimer", "iCount", "bQuestDone", "bDoOnce", "iState"]
	for entry in _instances:
		if _selected_node != null and entry.get("node") == _selected_node:
			var locals_dict: Dictionary = entry.get("locals", {})
			for k in locals_dict:
				if not list.has(k):
					list.append(k)
	return list


func _get_reference_candidates() -> Array[String]:
	var list: Array[String] = ["Player"]
	for entry in _instances:
		var node_name := String(entry.get("node_name", ""))
		if not node_name.is_empty() and not list.has(node_name):
			list.append(node_name)
	return list


func _get_command_candidates() -> Array[String]:
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
