class_name ScriptEngine
extends Node

## Owns every live script instance and runs the language's actual event
## dispatch mechanism (Begin/End blocks -- not function calls, per
## enginedocs/nv_script_interpreter_design.md's Execution model section).
##
## A real Node (like CellLoader/WorldStreamer already are), not a plain
## RefCounted -- GameMode/MenuMode blocks need a real per-frame cadence, and
## this project's own convention for "a system that needs _process()" is a
## sibling scene node, not a second, disconnected timer. The design doc's
## own goal is piggybacking WorldStreamer's *existing* cadence rather than a
## second one; this class doesn't touch world_streamer.gd yet (a real,
## deliberate scope cut for this first milestone -- see
## phases/5/00-script-interpreter-foundation.md), so for now it runs its
## own `_process()` -- still one real per-frame tick, just not literally the
## same call site yet.
##
## Parsed ScriptInterpreter instances are cached per SCPT form_id (one
## lex+parse per script, however many references use it), the same
## resource-caching discipline GamebryoMeshResolver already applies to
## parsed NIFs -- re-parsing identical SCTX per placement would be pure
## waste at real-game script-reuse scale.

var esm: EsmReader:
	set(value):
		esm = value
		function_registry.esm = value # ShowMessage's own MESG lookup needs this too

## Set by game.gd (the one real caller with an actual player Node) --
## propagated onto every dispatched ScriptExecutionContext so "player" (a
## real GECK global keyword, see ScriptInterpreter's own "name" case)
## resolves to something real instead of staying an unresolved name.
var player_node: Node = null
var function_registry: ScriptFunctionRegistry

var _interpreter_cache: Dictionary = {} # scpt_form_id (int) -> ScriptInterpreter
var _contexts: Dictionary = {} # Node -> ScriptExecutionContext
var _node_interpreter: Dictionary = {} # Node -> ScriptInterpreter, set in register_scripted_node()
var _node_script_form_ids: Dictionary = {} # Node -> int, retained for the runtime debug inspector
var _game_mode_nodes: Array = [] # Nodes whose script has a GameMode block -- the only ones _process() needs to visit every frame

func _init() -> void:
	function_registry = ScriptFunctionRegistry.new()

func _process(delta: float) -> void:
	for node in _game_mode_nodes:
		if not is_instance_valid(node):
			continue
		dispatch_event(node, "GameMode")

## Parses (or reuses the cached parse of) `script_form_id`'s real SCTX and
## attaches a fresh ScriptExecutionContext to `node`. Call once when a
## scripted Dynamic node is constructed -- `GamebryoObjectRegistry._finalize()`
## is the real call site (every construction path, threaded or not, funnels
## through it -- see that function's own doc comment).
##
## Dispatches a real "OnLoad" block immediately, if the script defines one
## -- real language semantics (confirmed via nv_script_interpreter_design.md's
## own real block-type census, OnLoad ranked #5 by usage): it fires once,
## the moment a reference is loaded into the world, which construction time
## *is* for this project's own Dynamic-object model. Deliberately NOT
## dispatching "OnActivate" here or anywhere yet -- game.gd's interact
## raycast still calls a Dynamic type's own activate() directly,
## unconditionally. A real script's OnActivate might not want that (a real,
## confirmed example: GSDocMitchellDoorScript's own bare `activate` call is
## exactly how a scripted door opts BACK into the engine's default
## open/close behavior -- meaning right now we run that default
## unconditionally for every door, scripted or not, which is only
## coincidentally correct for doors whose whole script is "just call
## activate"). Wiring OnActivate for real needs the interpreter to
## propagate a script-triggered activate() call's own outcome (Dictionary)
## back out through dispatch_event(), which doesn't exist yet -- a real,
## deliberately separate follow-up, not squeezed in here.
func register_scripted_node(node: Node, script_form_id: int) -> void:
	if script_form_id == 0 or esm == null:
		return
	var interpreter := _get_or_parse(script_form_id)
	if interpreter == null:
		return
	var ctx := ScriptExecutionContext.new(node)
	for local in interpreter.program["declarations"]:
		ctx.set_local(String(local["name"]), 0)
	_contexts[node] = ctx
	_node_interpreter[node] = interpreter
	_node_script_form_ids[node] = script_form_id
	if interpreter.has_block("GameMode") or interpreter.has_block("MenuMode"):
		_game_mode_nodes.append(node)
	if interpreter.has_block("OnLoad"):
		dispatch_event(node, "OnLoad")

func unregister_scripted_node(node: Node) -> void:
	_contexts.erase(node)
	_node_interpreter.erase(node)
	_node_script_form_ids.erase(node)
	_game_mode_nodes.erase(node)

func is_scripted(node: Node) -> bool:
	return _contexts.has(node)

## Runs every `block_type` block (case-insensitive) `node`'s script defines,
## if `node` is registered -- a real no-op otherwise (an unscripted node is
## the overwhelmingly common case, not an error). `action_ref` becomes
## GetActionRef()/IsActionRef's own answer for just this dispatch, per
## ScriptExecutionContext's own doc comment.
func dispatch_event(node: Node, block_type: String, action_ref: Node = null) -> void:
	if not _contexts.has(node):
		return
	var ctx: ScriptExecutionContext = _contexts[node]
	ctx.action_ref = action_ref
	ctx.player_node = player_node
	var interpreter: ScriptInterpreter = _node_interpreter.get(node)
	if interpreter != null:
		interpreter.run_block(block_type, ctx)

## Read-only runtime snapshot for the in-game Scripting debug tab.  Keeps
## the tab out of the engine's private instance dictionaries, while still
## reporting the real live contexts rather than a second parallel model.
func get_debug_instances() -> Array:
	var out: Array = []
	for node in _contexts:
		if not is_instance_valid(node):
			continue
		var form_id := int(_node_script_form_ids.get(node, 0))
		var interpreter: ScriptInterpreter = _node_interpreter.get(node)
		var ctx: ScriptExecutionContext = _contexts[node]
		var block_names: PackedStringArray = []
		if interpreter != null:
			for block in interpreter.program["blocks"]:
				block_names.append(String(block["blocktype"]))
		out.append({
			"node": node,
			"node_name": node.name,
			"script_form_id": form_id,
			"script_name": String(interpreter.program.get("script_name", "")) if interpreter != null else "",
			"blocks": block_names,
			"locals": ctx.locals.duplicate(),
			"source_text": String(esm.get_script_data(form_id).get("source_text", "")) if esm != null else "",
		})
	return out

func get_debug_usage() -> Dictionary:
	var local_slots := 0
	var non_zero := 0
	for ctx_value in _contexts.values():
		var ctx: ScriptExecutionContext = ctx_value
		local_slots += ctx.locals.size()
		for value in ctx.locals.values():
			if ScriptExecutionContext.is_truthy(value):
				non_zero += 1
	return { "contexts": _contexts.size(), "cached_scripts": _interpreter_cache.size(), "local_slots": local_slots, "non_zero_locals": non_zero }

## Runs exactly one console statement through the production lexer, parser,
## and interpreter.  A selected live script context retains its local state;
## without one, the real player is the calling reference.  This is a debug
## entry point, not a new console language.
func run_debug_line(line: String, target: Node = null) -> Dictionary:
	var text := line.strip_edges()
	if text == "":
		return { "ok": false, "message": "Enter a script statement." }
	var source := "scn DebugConsole\nbegin GameMode\n%s\nend" % text
	var program := ScriptParser.new(ScriptLexer.new(source).tokenize()).parse()
	if program["blocks"].is_empty():
		return { "ok": false, "message": "Could not parse console statement." }
	var ctx: ScriptExecutionContext
	if target != null and _contexts.has(target):
		ctx = _contexts[target]
	else:
		ctx = ScriptExecutionContext.new(player_node)
	ctx.player_node = player_node
	var interpreter := ScriptInterpreter.new(program, function_registry)
	var result: Variant = interpreter.run_block("GameMode", ctx)
	if result is Dictionary and result.has("error"):
		return { "ok": false, "message": String(result["error"]) }
	return { "ok": true, "result": result, "message": "OK" }

func _get_or_parse(script_form_id: int) -> ScriptInterpreter:
	if _interpreter_cache.has(script_form_id):
		return _interpreter_cache[script_form_id]
	var data: Dictionary = esm.get_script_data(script_form_id)
	if data.is_empty():
		return null
	var tokens := ScriptLexer.new(String(data["source_text"])).tokenize()
	var program := ScriptParser.new(tokens).parse()
	var interpreter := ScriptInterpreter.new(program, function_registry)
	_interpreter_cache[script_form_id] = interpreter
	return interpreter
