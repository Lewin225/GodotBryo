extends Node

## Runs object scripts for references. Autoloaded as ScriptServer.
##
## A reference's script is its base record's SCRI; its persistent state is
## the reference's ScriptInstance. Event blocks (OnActivate, OnTriggerEnter,
## ...) run whenever their event is dispatched, loaded or not. GameMode and
## MenuMode blocks run each frame only for references marked loaded through
## set_reference_loaded(). Parsed scripts are cached per SCPT FormID.

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

## Each frame: GameMode blocks of loaded references, then queued moves.
func _process(_delta: float) -> void:
	for reference: EsmReference in _loaded_game_mode.keys():
		dispatch_event(reference, "GameMode")
	apply_pending_moves()

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
	var instance := get_script_instance(reference)
	if instance == null:
		return null
	var interpreter := _get_or_parse(instance.script_form_id)
	if interpreter == null:
		return null
	var ctx := _context(reference, instance, action_ref)
	_start_run(ctx)
	return interpreter.run_block(block_type, ctx, action_ref)

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
func run_quest_block(quest: EsmBase, block_type: String) -> Variant:
	var instance := get_quest_instance(quest)
	if instance == null:
		return null
	var interpreter := _get_or_parse(instance.script_form_id)
	if interpreter == null:
		return null
	var ctx := _context(null, instance, null)
	_start_run(ctx)
	return interpreter.run_block(block_type, ctx)

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
	var now := Time.get_ticks_msec()
	ctx.seconds_passed = 0.0 if instance.last_run_msec < 0 else (now - instance.last_run_msec) / 1000.0
	instance.last_run_msec = now

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
		message_box.display_message(msg)
		return 1
	push_warning("ScriptServer: ShowMessage called but no MessageBox is set")
	return 0

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
