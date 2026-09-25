extends Node

## Runs object scripts for references. Autoloaded as ScriptServer.
##
## A reference's script is its base record's SCRI; its persistent state is
## the reference's ScriptInstance. Event blocks (OnActivate, OnTriggerEnter,
## ...) run whenever their event is dispatched, loaded or not. GameMode and
## MenuMode blocks run each frame only for references marked loaded through
## set_reference_loaded(). Parsed scripts are cached per SCPT FormID.

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

var _interpreter_cache: Dictionary = {} # SCPT FormID -> ScriptInterpreter
var _loaded_game_mode: Dictionary = {} # EsmReference -> true: loaded, has GameMode/MenuMode
var _instances: Dictionary = {} # EsmReference -> true: every reference whose script has run
var _last_button_pressed: int = -1

func _ready() -> void:
	function_registry.show_message_handler = _handle_show_message
	function_registry.get_button_pressed_handler = _handle_get_button_pressed
	var esm_server := get_node_or_null("/root/EsmServer")
	if esm_server != null:
		if esm_server.is_ready():
			function_registry.esm = esm_server.reader
		else:
			esm_server.esm_ready.connect(func(): function_registry.esm = esm_server.reader, CONNECT_ONE_SHOT)

func _process(_delta: float) -> void:
	for reference: EsmReference in _loaded_game_mode.keys():
		dispatch_event(reference, "GameMode")

## The SCPT FormID `reference` runs: its base record's SCRI, or 0.
static func get_script_form_id(reference: EsmReference) -> int:
	if reference == null or reference.base == null or not "script_form_id" in reference.base:
		return 0
	return int(reference.base.script_form_id)

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
	return interpreter.run_block(block_type, ctx, action_ref)

## Whether dispatching `block_type` with `action_ref` would run a block.
func has_block_for(reference: EsmReference, block_type: String, action_ref: EsmReference = null) -> bool:
	var instance := get_script_instance(reference)
	if instance == null:
		return false
	var interpreter := _get_or_parse(instance.script_form_id)
	return interpreter != null and interpreter.has_block_for(block_type, _context(reference, instance, action_ref), action_ref)

## Marks a reference's cell loaded or unloaded. Loading runs its OnLoad block
## and starts its GameMode/MenuMode blocks each frame; unloading stops them.
func set_reference_loaded(reference: EsmReference, loaded: bool) -> void:
	if not loaded:
		_loaded_game_mode.erase(reference)
		return
	var instance := get_script_instance(reference)
	if instance == null:
		return
	var interpreter := _get_or_parse(instance.script_form_id)
	if interpreter == null:
		return
	if interpreter.has_block("GameMode") or interpreter.has_block("MenuMode"):
		_loaded_game_mode[reference] = true
	if interpreter.has_block("OnLoad"):
		dispatch_event(reference, "OnLoad")

func is_reference_loaded(reference: EsmReference) -> bool:
	return _loaded_game_mode.has(reference)

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

## Snapshot of every reference whose script has run, for the Scripting tab.
func get_debug_instances() -> Array:
	var out: Array = []
	for reference: EsmReference in _instances:
		var instance := reference.script_instance
		if instance == null:
			continue
		var interpreter := _get_or_parse(instance.script_form_id)
		var block_names: PackedStringArray = []
		if interpreter != null:
			for block in interpreter.program["blocks"]:
				block_names.append(String(block["blocktype"]))
		out.append({
			"reference": reference,
			"name": reference.instance_id,
			"loaded": _loaded_game_mode.has(reference),
			"script_form_id": instance.script_form_id,
			"script_name": String(interpreter.program.get("script_name", "")) if interpreter != null else "",
			"blocks": block_names,
			"locals": instance.locals.duplicate(),
			"source_text": String(function_registry.esm.get_script_data(instance.script_form_id).get("source_text", "")) if function_registry.esm != null else "",
		})
	return out

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
	return { "instances": _instances.size(), "loaded": _loaded_game_mode.size(), "cached_scripts": _interpreter_cache.size(), "local_slots": local_slots, "non_zero_locals": non_zero }

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

func _handle_show_message(msg: Dictionary, _ctx: ScriptExecutionContext) -> int:
	if message_box != null:
		message_box.display_message(msg)
		return 1
	push_warning("ScriptServer: ShowMessage called but no MessageBox is set")
	return 0

## Returns the last MessageBox button clicked and clears it.
func _handle_get_button_pressed(_ctx: ScriptExecutionContext) -> int:
	var pressed := _last_button_pressed
	_last_button_pressed = -1
	return pressed

func _on_message_box_button_clicked(button_idx: int) -> void:
	_last_button_pressed = button_idx
