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

var esm: EsmReader
var function_registry: ScriptFunctionRegistry

var _interpreter_cache: Dictionary = {} # scpt_form_id (int) -> ScriptInterpreter
var _contexts: Dictionary = {} # Node -> ScriptExecutionContext
var _node_interpreter: Dictionary = {} # Node -> ScriptInterpreter, set in register_scripted_node()
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
## scripted Dynamic node is constructed (object_registry.gd's own factories
## are the natural call site -- not wired in yet this pass, a real,
## deliberate integration step left for the next milestone so this class
## can be tested standalone first).
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
	if interpreter.has_block("GameMode") or interpreter.has_block("MenuMode"):
		_game_mode_nodes.append(node)

func unregister_scripted_node(node: Node) -> void:
	_contexts.erase(node)
	_node_interpreter.erase(node)
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
	var interpreter: ScriptInterpreter = _node_interpreter.get(node)
	if interpreter != null:
		interpreter.run_block(block_type, ctx)

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
