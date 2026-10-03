extends Node

## Runs object scripts for references. Autoloaded as ScriptServer.
##
## A reference's script is its base record's SCRI; its persistent state is
## the reference's ScriptInstance. Event blocks (OnActivate, OnTriggerEnter,
## ...) run whenever their event is dispatched, loaded or not. GameMode and
## MenuMode blocks run each frame only for references marked loaded through
## set_reference_loaded(). Parsed scripts are cached per SCPT FormID.

## The game entered (true) or left (false) menu mode.
signal menu_mode_changed(in_menu_mode: bool)
## DisablePlayerControls / EnablePlayerControls changed the disabled controls.
signal player_controls_changed(disabled: int)

## Player controls DisablePlayerControls and EnablePlayerControls name, in
## their argument order (GECK wiki DisablePlayerControls, through search
## summaries). Movement also stops activating objects; Looking locks the view.
const CONTROL_MOVEMENT := 0x01
const CONTROL_PIPBOY := 0x02
const CONTROL_FIGHTING := 0x04
const CONTROL_POV := 0x08
const CONTROL_LOOKING := 0x10
const CONTROL_ROLLOVER_TEXT := 0x20
const CONTROL_SNEAKING := 0x40

## Menu type IDs, as `Begin MenuMode <id>` names them (GECK wiki, "MenuMode
## (Function)", `enginedocs/Geck`). 1 and 2 are groups: the "main four"
## (stats, inventory, Pip-Boy) and any other menu.
const MENU_GROUP_MAIN_FOUR := 1
const MENU_GROUP_OTHER := 2
const MENU_CONSOLE := 3
const MENU_MESSAGE := 1001
const MENU_DIALOG := 1009
const MENU_LOCKPICK := 1014
const MENU_RACE := 1036
const MENU_TEXT_EDIT := 1051
const MENU_HACKING := 1055
const MENU_COMPUTERS := 1057
const MENU_LOVE_TESTER := 1074

## A queued move was applied to `reference`.
signal reference_teleported(reference: EsmReference, old_space_form_id: int, new_space_form_id: int)

## The reference `player` resolves to in scripts. Null while no actor is
## possessed by the player.
var player_reference: EsmReference = null
## The player's physics body, for body-level commands (ToggleCollision).
var player_node: Node = null:
	set(value):
		player_node = value
		function_registry.player_node = value
## Dialog used by ShowMessage; GetButtonPressed reads its last click.
var message_box: MessageBox = null:
	set(value):
		if message_box != null and message_box.button_clicked.is_connected(_on_message_box_button_clicked):
			message_box.button_clicked.disconnect(_on_message_box_button_clicked)
		message_box = value
		if message_box != null:
			message_box.button_clicked.connect(_on_message_box_button_clicked)

var function_registry := ScriptFunctionRegistry.new()
## Seconds of game time, advanced by _process: the clock GetSecondsPassed
## measures between a script's runs.
var clock := 0.0
## Opens the UI for a menu a script asks for (GetPlayerName, ShowRaceMenu,
## ShowLoveTesterMenuParams): called with the menu ID and its parameters,
## returns true when a UI opened it; that UI then calls enter_menu and
## exit_menu. Set by the player's controller.
var menu_opener: Callable
var _open_menus: Array[int] = [] # menus open, most recent last
## The player controls scripts have disabled (CONTROL_* flags, in
## DisablePlayerControls' argument order).
@export_flags("Movement", "Pip-Boy", "Fighting", "POV", "Looking", "Rollover Text", "Sneaking")
var disabled_player_controls := 0
## The game's global variables (GLOB), seeded from the ESM on first use. World
## state: a save stores this resource.
var globals := GlobalVariables.new()

var _interpreter_cache: Dictionary = {} # SCPT FormID -> ScriptInterpreter
var _loaded: Dictionary = {} # EsmReference -> true: every loaded reference with a script
var _loaded_game_mode: Dictionary = {} # the loaded ones with GameMode/MenuMode
var _instances: Dictionary = {} # EsmReference -> true: every reference whose script has run
var _last_button_pressed: int = -1
## The reference whose script showed the open message box; only its
## GetButtonPressed sees the button clicked.
var _message_owner: EsmReference = null

var _pending_moves: Dictionary = {} # EsmReference -> {space_form_id, position, rotation}
var _result_script_cache: Dictionary = {} # result script source -> ScriptInterpreter
var _condition_evaluator: ConditionEvaluator = null
var _variable_names: Dictionary = {} # SCPT FormID -> {SLSD index: SCVR name}

const _DECLARATION_TYPES := ["int", "short", "long", "float", "ref"]

func _ready() -> void:
	# Runs after default-priority nodes' _process each frame. Physics bodies
	# sync their references in _physics_process, which runs earlier still, so
	# queued moves are applied after that frame's body sync.
	process_priority = 100
	function_registry.script_server = self
	function_registry.show_message_handler = _handle_show_message
	function_registry.get_button_pressed_handler = _handle_get_button_pressed
	var esm_server := get_node_or_null("/root/EsmServer")
	if esm_server != null:
		if esm_server.is_ready():
			function_registry.esm = esm_server.reader
		else:
			esm_server.esm_ready.connect(func(): function_registry.esm = esm_server.reader, CONNECT_ONE_SHOT)

## Each frame: advances the script clock, runs loaded references' GameMode
## blocks, or in menu mode their MenuMode blocks for the open menu, then
## applies queued moves.
func _process(delta: float) -> void:
	clock += delta
	for reference: EsmReference in _loaded_game_mode.keys():
		if is_menu_mode():
			dispatch_event_for(reference, "MenuMode", get_menu())
		else:
			dispatch_event(reference, "GameMode")
	apply_pending_moves()

## A menu opens: the game is in menu mode until every open menu has closed.
## GameMode blocks and quest scripts' GameMode stop; MenuMode blocks accepting
## the most recently opened menu run each frame instead; dialogue lines pause.
func enter_menu(menu_id: int) -> void:
	var was_menu_mode := is_menu_mode()
	_open_menus.append(menu_id)
	if not was_menu_mode:
		menu_mode_changed.emit(true)

## A menu closes; the game leaves menu mode when it was the last open.
func exit_menu(menu_id: int) -> void:
	_open_menus.erase(menu_id)
	if _open_menus.is_empty():
		menu_mode_changed.emit(false)

## Disables the CONTROL_* flags in `controls` (DisablePlayerControls).
func disable_player_controls(controls: int) -> void:
	_set_disabled_player_controls(disabled_player_controls | controls)

## Enables the CONTROL_* flags in `controls` (EnablePlayerControls).
func enable_player_controls(controls: int) -> void:
	_set_disabled_player_controls(disabled_player_controls & ~controls)

## Whether the player control `control` (a CONTROL_* flag) is enabled.
func is_player_control_enabled(control: int) -> bool:
	return (disabled_player_controls & control) == 0

func _set_disabled_player_controls(controls: int) -> void:
	if controls == disabled_player_controls:
		return
	disabled_player_controls = controls
	player_controls_changed.emit(controls)

func is_menu_mode() -> bool:
	return not _open_menus.is_empty()

## Whether menu `menu_type` is open: any menu for 0, the "main four" group for
## 1 (none of which exist yet, so false), any other menu for 2, else that
## specific menu.
func is_menu_open(menu_type: int) -> bool:
	match menu_type:
		0: return is_menu_mode()
		MENU_GROUP_MAIN_FOUR: return false
		MENU_GROUP_OTHER: return is_menu_mode()
	return _open_menus.has(menu_type)

## The most recently opened menu, or 0 outside menu mode.
func get_menu() -> int:
	return _open_menus.back() if not _open_menus.is_empty() else 0

## Runs, once, the MenuMode blocks accepting the open menu of every running
## quest and loaded reference.
func run_menu_mode_blocks() -> void:
	var quests := get_node_or_null("/root/QuestServer")
	if quests != null:
		for state: QuestState in quests.get_quest_states():
			if state.running:
				run_quest_block(state.quest, "MenuMode", get_menu())
	for reference: EsmReference in _loaded_game_mode.keys():
		dispatch_event_for(reference, "MenuMode", get_menu())

## Applies every queued move: sets rotation, then space and position together
## (one cell refresh, so anything reacting to the cell change sees the final
## transform), then emits the reference's teleported and
## reference_teleported. Moves queued while applying wait for the next call.
func apply_pending_moves() -> void:
	var moves := _pending_moves
	_pending_moves = {}
	for reference: EsmReference in moves:
		var move: Dictionary = moves[reference]
		var old_space := reference.current_space_form_id
		var new_space := int(move["space_form_id"])
		reference.rotation = move["rotation"]
		reference.set_location(new_space, move["position"])
		reference.teleported.emit(old_space, new_space)
		reference_teleported.emit(reference, old_space, new_space)

## The SCPT FormID `reference` runs: its base record's SCRI, or 0.
static func get_script_form_id(reference: EsmReference) -> int:
	return reference.base.script_form_id if reference != null and reference.base != null else 0

## Whether a list of CTDA conditions passes for `context` (ConditionEvaluator).
func evaluate_conditions(conditions: Array[Condition], context: ConditionContext) -> bool:
	if _condition_evaluator == null:
		_condition_evaluator = ConditionEvaluator.new(self)
	return _condition_evaluator.evaluate(conditions, context)

## The name of a script's local variable by its SLSD index, or "" when the
## script declares none with that index. Conditions (GetQuestVariable,
## GetScriptVariable) name variables by index. Read from the SCPT's SLSD/SCVR
## pairs, once per script.
func script_variable_name(script_form_id: int, index: int) -> String:
	if not _variable_names.has(script_form_id):
		var names := {}
		var esm_server := EsmReference.get_esm_server()
		var raw: Dictionary = esm_server.reader.get_record_data(script_form_id) if esm_server != null and esm_server.reader != null else {}
		var pending := -1
		for sub: Dictionary in raw.get("subrecords", []):
			var bytes: PackedByteArray = sub.get("data", PackedByteArray())
			match String(sub.get("type", "")):
				"SLSD":
					pending = int(bytes.decode_u32(0)) if bytes.size() >= 4 else -1
				"SCVR":
					if pending >= 0:
						names[pending] = bytes.get_string_from_utf8()
					pending = -1
		_variable_names[script_form_id] = names
	return String(_variable_names[script_form_id].get(index, ""))

## The reference's ScriptInstance, created with its declared locals set to 0
## the first time it is needed. Null when the reference has no script.
func get_script_instance(reference: EsmReference) -> ScriptInstance:
	if reference == null:
		return null
	var script_form_id := get_script_form_id(reference)
	if script_form_id == 0:
		return null
	if reference.script_instance == null or reference.script_instance.script_form_id != script_form_id:
		var interpreter := _get_or_parse(script_form_id)
		if interpreter == null:
			return null
		var instance := ScriptInstance.new()
		instance.script_form_id = script_form_id
		for local in interpreter.program["declarations"]:
			instance.set_local(String(local["name"]), 0)
		reference.script_instance = instance
	_instances[reference] = true
	return reference.script_instance

## Runs every `block_type` block of the reference's script that accepts
## `action_ref`: a parameterised block (`Begin OnActivate Player`) runs only
## when its parameter names the action reference. Returns the value of the
## last statement run, or null.
func dispatch_event(reference: EsmReference, block_type: String, action_ref: EsmReference = null) -> Variant:
	return dispatch_event_for(reference, block_type, action_ref, action_ref)

## Runs every `block_type` block of the reference's script that accepts
## `subject`, which need not be a reference: a menu ID (`Begin MenuMode
## 1036`) or a topic (`Begin SayToDone VCG01Intro`).
func dispatch_event_for(reference: EsmReference, block_type: String, subject: Variant, action_ref: EsmReference = null) -> Variant:
	var instance := get_script_instance(reference)
	if instance == null:
		return null
	var interpreter := _get_or_parse(instance.script_form_id)
	if interpreter == null:
		return null
	var ctx := _context(reference, instance, action_ref)
	_start_run(ctx)
	return interpreter.run_block(block_type, ctx, subject)

## Whether dispatching `block_type` with `action_ref` would run a block.
func has_block_for(reference: EsmReference, block_type: String, action_ref: EsmReference = null) -> bool:
	var instance := get_script_instance(reference)
	if instance == null:
		return false
	var interpreter := _get_or_parse(instance.script_form_id)
	return interpreter != null and interpreter.has_block_for(block_type, _context(reference, instance, action_ref), action_ref)

## `activator` activates `target`. Runs the target's OnActivate block that
## accepts the activator; when there is none, performs the built-in
## activation, as if the block were `Begin OnActivate / Activate / End`.
func activate(target: EsmReference, activator: EsmReference) -> void:
	if target == null:
		return
	if has_block_for(target, "OnActivate", activator):
		dispatch_event(target, "OnActivate", activator)
	else:
		default_activate(target, activator)

## Built-in activation of `target` by `activator`, without running any script
## block: the target's default_activate(), then its loaded node, if any,
## presents the result.
func default_activate(target: EsmReference, activator: EsmReference) -> void:
	if target == null:
		return
	target.default_activate(activator)
	var node := EsmNode.node_for(target)
	if node != null:
		node.on_activated(activator)

## Queues moving `reference` to `position` / `rotation` (metres, Gamebryo
## Z-up; radians) in `space_form_id`. A later move of the same reference
## before the queue is applied replaces this one.
func move_reference(reference: EsmReference, space_form_id: int, position: Vector3, rotation: Vector3) -> void:
	if reference == null:
		return
	_pending_moves[reference] = {"space_form_id": space_form_id, "position": position, "rotation": rotation}

## The queued move for `reference`, or an empty Dictionary.
func get_pending_move(reference: EsmReference) -> Dictionary:
	return _pending_moves.get(reference, {})

## `actor` starts using `target`. Furniture takes a free active marker
## (`marker` when given and free); any other reference is single-user. An
## actor using something else stops using it first. Returns false when
## `actor` is not an actor or `target` is fully occupied.
func begin_use(actor: EsmReference, target: EsmReference, marker := -1) -> bool:
	var user := actor as ActorReference
	if user == null or target == null:
		return false
	if user.using == target:
		return true
	var slot := -1
	if target is FurnitureReference:
		slot = _free_furniture_slot(target as FurnitureReference, marker)
		if slot < 0:
			return false
	elif target.used_by != null and target.used_by != user:
		return false
	if user.using != null:
		end_use(user)
	if target is FurnitureReference:
		(target as FurnitureReference).occupants[slot] = user
		user.using_marker = (target.base as FurnitureBase).get_active_markers()[slot]
	else:
		target.used_by = user
		user.using_marker = -1
	user.using = target
	user.using_changed.emit(null, target)
	return true

## `actor` stops using whatever it is using.
func end_use(actor: EsmReference) -> void:
	var user := actor as ActorReference
	if user == null or user.using == null:
		return
	var target := user.using
	if target is FurnitureReference:
		var occupants := (target as FurnitureReference).occupants
		for i in occupants.size():
			if occupants[i] == user:
				occupants[i] = null
	elif target.used_by == user:
		target.used_by = null
	user.using = null
	user.using_marker = -1
	user.using_changed.emit(target, null)

## Locks a door or terminal, at `level` when given: 0-100 for doors (255
## requires the key), 0-5 for terminals (5 cannot be hacked).
func lock(reference: EsmReference, level := -1) -> void:
	if not (reference is DoorReference or reference is TerminalReference):
		return
	if level >= 0:
		reference.lock_level = level
	reference.is_locked = true

func unlock(reference: EsmReference) -> void:
	if reference is DoorReference or reference is TerminalReference:
		reference.is_locked = false

func _free_furniture_slot(furniture: FurnitureReference, marker: int) -> int:
	var markers := (furniture.base as FurnitureBase).get_active_markers() if furniture.base is FurnitureBase else PackedInt32Array()
	if furniture.occupants.size() != markers.size():
		furniture.occupants.resize(markers.size())
	if marker >= 0:
		var slot := markers.find(marker)
		return slot if slot >= 0 and furniture.occupants[slot] == null else -1
	return furniture.occupants.find(null)

## A quest's script variables: its QuestState's ScriptInstance, created with
## the declared locals at 0 on first use. Null when the quest has no script.
func get_quest_instance(quest: EsmBase) -> ScriptInstance:
	var state := _quest_state(quest)
	if state == null or quest.script_form_id == 0:
		return null
	if state.script_instance == null:
		var interpreter := _get_or_parse(quest.script_form_id)
		if interpreter == null:
			return null
		var instance := ScriptInstance.new()
		instance.script_form_id = quest.script_form_id
		for local in interpreter.program["declarations"]:
			instance.set_local(String(local["name"]), 0)
		state.script_instance = instance
	return state.script_instance

func _quest_state(quest: EsmBase) -> QuestState:
	var quest_server := get_node_or_null("/root/QuestServer")
	return quest_server.get_quest_state(quest) if quest_server != null else null

## Runs `block_type` blocks of a quest's script, with the quest's variables and
## no calling reference.
func run_quest_block(quest: EsmBase, block_type: String, subject: Variant = null) -> Variant:
	var instance := get_quest_instance(quest)
	if instance == null:
		return null
	var interpreter := _get_or_parse(instance.script_form_id)
	if interpreter == null:
		return null
	var ctx := _context(null, instance, null)
	_start_run(ctx)
	return interpreter.run_block(block_type, ctx, subject)

## A script opens menu `menu_id` (GetPlayerName: 1051, ShowRaceMenu: 1036,
## ShowLoveTesterMenuParams: 1074, with {"points": n}). The player's UI opens
## it through `menu_opener`; with no UI for it (headless, or no player), the
## menu opens and closes at once, running the MenuMode blocks that accept it
## once.
func open_menu(menu_id: int, params: Dictionary = {}) -> void:
	if menu_opener.is_valid() and menu_opener.call(menu_id, params):
		return
	enter_menu(menu_id)
	run_menu_mode_blocks()
	exit_menu(menu_id)

## Marks a reference's cell loaded or unloaded. Loading runs its OnLoad block
## and starts its GameMode/MenuMode blocks each frame; unloading stops them.
func set_reference_loaded(reference: EsmReference, loaded: bool) -> void:
	if not loaded:
		_loaded.erase(reference)
		_loaded_game_mode.erase(reference)
		return
	if _loaded.has(reference):
		return
	var instance := get_script_instance(reference)
	if instance == null:
		return
	var interpreter := _get_or_parse(instance.script_form_id)
	if interpreter == null:
		return
	_loaded[reference] = true
	if interpreter.has_block("GameMode") or interpreter.has_block("MenuMode"):
		_loaded_game_mode[reference] = true
	if interpreter.has_block("OnLoad"):
		dispatch_event(reference, "OnLoad")

## Whether a reference with a script is in a loaded CELL.
func is_reference_loaded(reference: EsmReference) -> bool:
	return _loaded.has(reference)

## Runs a result script: a bare statement list with no Begin/End, as on
## terminal menu items, dialogue and packages. `subject` is the implicit
## reference of its calls and `action_ref` the activator. A result script has
## its own locals, declared in its source and fresh on every run; it reads and
## writes other references' variables only as `SomeREF.var`.
func run_result_script(source: String, subject: EsmReference, action_ref: EsmReference = null) -> Variant:
	if source.strip_edges().is_empty():
		return null
	var interpreter: ScriptInterpreter = _result_script_cache.get(source)
	if interpreter == null:
		var declarations := PackedStringArray()
		var statements := PackedStringArray()
		for line in source.split("\n"):
			var words := line.strip_edges().split(" ", false)
			if not words.is_empty() and _DECLARATION_TYPES.has(words[0].to_lower()):
				declarations.append(line)
			else:
				statements.append(line)
		var wrapped := "scn ResultScript\n%s\nbegin GameMode\n%s\nend\n" % ["\n".join(declarations), "\n".join(statements)]
		interpreter = ScriptInterpreter.new(ScriptParser.new(ScriptLexer.new(wrapped).tokenize()).parse(), function_registry)
		_result_script_cache[source] = interpreter
	var ctx := _context(subject, ScriptInstance.new(), action_ref)
	for local in interpreter.program["declarations"]:
		ctx.set_local(String(local["name"]), 0)
	return interpreter.run_block("GameMode", ctx)

## Runs one console statement through the production lexer, parser and
## interpreter. With a target reference the statement runs as that
## reference, against its locals; without one it has no calling reference.
func run_debug_line(line: String, target: EsmReference = null) -> Dictionary:
	var text := line.strip_edges()
	if text == "":
		return { "ok": false, "message": "Enter a script statement." }
	var source := "scn DebugConsole\nbegin GameMode\n%s\nend" % text
	var program := ScriptParser.new(ScriptLexer.new(source).tokenize()).parse()
	if program["blocks"].is_empty():
		return { "ok": false, "message": "Could not parse console statement." }
	var instance := get_script_instance(target) if target != null else null
	var ctx := _context(target, instance, null)
	var result: Variant = ScriptInterpreter.new(program, function_registry).run_block("GameMode", ctx)
	if result is Dictionary and result.has("error"):
		return { "ok": false, "message": String(result["error"]) }
	return { "ok": true, "result": result, "message": "OK" }

## Snapshot of every script with variables, for the Script Engine tab: each
## reference whose script has run (`reference` set, `quest` null), then each
## quest whose script variables exist (`quest` set, `reference` null).
func get_debug_instances() -> Array:
	var out: Array = []
	for reference: EsmReference in _instances:
		var instance := reference.script_instance
		if instance == null:
			continue
		var entry := _debug_entry(instance)
		entry["reference"] = reference
		entry["quest"] = null
		entry["name"] = reference.instance_id
		entry["loaded"] = _loaded.has(reference)
		out.append(entry)
	var quest_server := get_node_or_null("/root/QuestServer")
	if quest_server != null:
		for state: QuestState in quest_server.get_quest_states():
			if state.script_instance == null or state.quest == null:
				continue
			var entry := _debug_entry(state.script_instance)
			entry["reference"] = null
			entry["quest"] = state.quest
			entry["name"] = state.quest.editor_id
			entry["loaded"] = state.running
			out.append(entry)
	return out

func _debug_entry(instance: ScriptInstance) -> Dictionary:
	var interpreter := _get_or_parse(instance.script_form_id)
	var block_names: PackedStringArray = []
	if interpreter != null:
		for block in interpreter.program["blocks"]:
			block_names.append(String(block["blocktype"]))
	return {
		"script_form_id": instance.script_form_id,
		"script_name": String(interpreter.program.get("script_name", "")) if interpreter != null else "",
		"blocks": block_names,
		"locals": instance.locals.duplicate(),
		"source_text": String(function_registry.esm.get_script_data(instance.script_form_id).get("source_text", "")) if function_registry.esm != null else "",
	}

func get_debug_usage() -> Dictionary:
	var local_slots := 0
	var non_zero := 0
	for reference: EsmReference in _instances:
		if reference.script_instance == null:
			continue
		for value in reference.script_instance.locals.values():
			local_slots += 1
			if ScriptExecutionContext.is_truthy(value):
				non_zero += 1
	return { "instances": _instances.size(), "loaded": _loaded.size(), "cached_scripts": _interpreter_cache.size(), "local_slots": local_slots, "non_zero_locals": non_zero }

## Marks a script run: the context's seconds_passed is the real time since the
## instance last ran, and the instance's clock restarts now.
func _start_run(ctx: ScriptExecutionContext) -> void:
	var instance := ctx.instance
	ctx.seconds_passed = 0.0 if instance.last_run_time < 0.0 else clock - instance.last_run_time
	instance.last_run_time = clock

func _context(reference: EsmReference, instance: ScriptInstance, action_ref: EsmReference) -> ScriptExecutionContext:
	var ctx := ScriptExecutionContext.new(reference, instance)
	ctx.action_ref = action_ref
	ctx.player_reference = player_reference
	return ctx

func _get_or_parse(script_form_id: int) -> ScriptInterpreter:
	if _interpreter_cache.has(script_form_id):
		return _interpreter_cache[script_form_id]
	if function_registry.esm == null:
		return null
	var data: Dictionary = function_registry.esm.get_script_data(script_form_id)
	if data.is_empty():
		return null
	var program := ScriptParser.new(ScriptLexer.new(String(data["source_text"])).tokenize()).parse()
	var interpreter := ScriptInterpreter.new(program, function_registry)
	_interpreter_cache[script_form_id] = interpreter
	return interpreter

func _handle_show_message(msg: Dictionary, ctx: ScriptExecutionContext) -> int:
	_message_owner = ctx.calling_reference
	_last_button_pressed = -1
	if message_box != null:
		message_box.display_message(_with_available_buttons(msg))
		return 1
	push_warning("ScriptServer: ShowMessage called but no MessageBox is set")
	return 0

## `msg` showing only the buttons whose conditions pass, each keeping its
## authored index for GetButtonPressed. Conditions run on the player: button
## conditions test the player's skills and items (GSBrokenSMGMsg: Repair >= 25),
## though the original's subject is not verified.
func _with_available_buttons(msg: Dictionary) -> Dictionary:
	var esm_server := EsmReference.get_esm_server()
	var message: MessageBase = esm_server.get_base(int(msg.get("form_id", 0))) as MessageBase if esm_server != null else null
	if message == null:
		return msg
	var context := ConditionContext.new(esm_server.get_player_reference())
	context.owner_label = "MESG %s" % message.editor_id
	var texts := PackedStringArray()
	var indices: Array[int] = []
	for i in message.buttons.size():
		if evaluate_conditions(message.buttons[i].conditions, context):
			texts.append(message.buttons[i].text)
			indices.append(i)
	if indices.size() == message.buttons.size():
		return msg
	var filtered := msg.duplicate()
	filtered["buttons"] = texts
	filtered["button_indices"] = indices
	return filtered

## The button clicked on the message box this script's reference showed, once;
## -1 until then, and always -1 for any other reference.
func _handle_get_button_pressed(ctx: ScriptExecutionContext) -> int:
	if ctx.calling_reference != _message_owner or _last_button_pressed < 0:
		return -1
	var pressed := _last_button_pressed
	_last_button_pressed = -1
	_message_owner = null
	return pressed

func _on_message_box_button_clicked(button_idx: int) -> void:
	_last_button_pressed = button_idx
