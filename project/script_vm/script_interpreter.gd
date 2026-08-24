class_name ScriptInterpreter
extends RefCounted

## Tree-walking interpreter over one ScriptParser.parse() result, per
## enginedocs/nv_script_interpreter_design.md's "Proposed pipeline" --
## never a bytecode VM. One ScriptInterpreter per parsed script (cached,
## shared across every calling reference the same way NifReader/parsed
## meshes are already cached elsewhere in this project); per-instance state
## lives on the caller-owned ScriptExecutionContext instead, so the same
## parsed program safely runs for many references at once.

var program: Dictionary
var function_registry: ScriptFunctionRegistry

func _init(parsed_program: Dictionary, registry: ScriptFunctionRegistry) -> void:
	program = parsed_program
	function_registry = registry

func has_block(block_type: String) -> bool:
	for block in program["blocks"]:
		if String(block["blocktype"]).to_lower() == block_type.to_lower():
			return true
	return false

## Runs every block whose blocktype matches (case-insensitive). Real
## language behavior also gates on a block's own params (e.g. `OnTrigger
## Play` vs. plain `OnTrigger`) -- not implemented this pass, a real,
## documented gap (every same-named block runs regardless of its params).
func run_block(block_type: String, ctx: ScriptExecutionContext) -> Variant:
	var result: Variant = null
	for block in program["blocks"]:
		if String(block["blocktype"]).to_lower() == block_type.to_lower():
			result = _exec_stmts(block["stmts"], ctx)
	return result

func _exec_stmts(stmts: Array, ctx: ScriptExecutionContext) -> Variant:
	var result: Variant = null
	for stmt in stmts:
		result = _exec_stmt(stmt, ctx)
	return result

func _exec_stmt(stmt: Dictionary, ctx: ScriptExecutionContext) -> Variant:
	match String(stmt["kind"]):
		"set":
			var value: Variant = _eval(stmt["expr"], ctx)
			_assign(String(stmt["target"]), value, ctx)
			return value
		"if":
			for branch in stmt["branches"]:
				if ScriptExecutionContext.is_truthy(_eval(branch["cond"], ctx)):
					return _exec_stmts(branch["stmts"], ctx)
			return _exec_stmts(stmt.get("else_stmts", []), ctx)
		"call":
			return _eval(stmt, ctx) # bare call statement -- evaluated for its side effect only
		"noop":
			pass # a stray reserved keyword the parser skipped -- see script_parser.gd's own doc comment on _RESERVED_KEYWORDS
	return null

func _assign(target: String, value: Variant, ctx: ScriptExecutionContext) -> void:
	if not target.contains("."):
		ctx.set_local(target, value)
		return
	# Cross-reference assignment (`OtherRef.Var`) -- design doc's
	# "Cross-reference" storage tier. Real, deliberate gap: this
	# interpreter has no global editor-id -> ExecutionContext registry yet
	# to route the write to the right instance's own locals.
	push_warning("ScriptInterpreter: cross-reference assignment to '%s' not implemented, dropped" % target)

func _eval(expr: Dictionary, ctx: ScriptExecutionContext) -> Variant:
	match String(expr["kind"]):
		"literal":
			return expr["value"]
		"var":
			return ctx.get_local(String(expr["name"]))
		"name":
			# A raw reference/editor-ID literal (script_parser.gd's own doc
			# comment on _parse_ident_primary()) -- evaluates to its own
			# literal text, EXCEPT the one real, special-cased global GECK
			# keyword this interpreter actually resolves: "player", always
			# meaning the real player character (distinct from
			# ctx.action_ref -- see ScriptExecutionContext's own doc
			# comment). Whichever function receives any other name
			# (ShowMessage's MESG lookup, ...) decides what it means; this
			# interpreter has no general editor-id -> Node/Resource registry
			# to resolve the rest through yet, a real, deliberate gap noted
			# elsewhere in this file.
			var raw_name := String(expr["name"])
			if raw_name.to_lower() == "player" and ctx.player_node != null:
				return ctx.player_node
			return raw_name
		"unary":
			return -_to_number(_eval(expr["operand"], ctx))
		"binop":
			return _eval_binop(expr, ctx)
		"call":
			return _eval_call(expr, ctx)
	return null

func _eval_binop(expr: Dictionary, ctx: ScriptExecutionContext) -> Variant:
	var op := String(expr["op"])
	if op == "&&":
		return 1 if (ScriptExecutionContext.is_truthy(_eval(expr["left"], ctx)) and ScriptExecutionContext.is_truthy(_eval(expr["right"], ctx))) else 0
	if op == "||":
		return 1 if (ScriptExecutionContext.is_truthy(_eval(expr["left"], ctx)) or ScriptExecutionContext.is_truthy(_eval(expr["right"], ctx))) else 0
	var l: Variant = _eval(expr["left"], ctx)
	var r: Variant = _eval(expr["right"], ctx)
	match op:
		"+": return _to_number(l) + _to_number(r)
		"-": return _to_number(l) - _to_number(r)
		"*": return _to_number(l) * _to_number(r)
		"/": return (_to_number(l) / _to_number(r)) if _to_number(r) != 0 else 0.0
		"%": return fmod(_to_number(l), _to_number(r)) if _to_number(r) != 0 else 0.0
		# Real language rule (design doc's Boolean coercion section):
		# comparisons always yield exactly 1 or 0.
		"==": return 1 if ScriptExecutionContext.safe_equal(l, r) else 0
		"!=": return 0 if ScriptExecutionContext.safe_equal(l, r) else 1
		">": return 1 if _to_number(l) > _to_number(r) else 0
		"<": return 1 if _to_number(l) < _to_number(r) else 0
		">=": return 1 if _to_number(l) >= _to_number(r) else 0
		"<=": return 1 if _to_number(l) <= _to_number(r) else 0
	return null

func _to_number(value: Variant) -> float:
	if value == null:
		return 0.0
	if value is Node:
		return 0.0 # a ref used numerically -- real language edge case, treated as 0 rather than crashing
	return float(value)

func _eval_call(expr: Dictionary, ctx: ScriptExecutionContext) -> Variant:
	var args := []
	for arg_expr in expr["args"]:
		args.append(_eval(arg_expr, ctx))
	var call_ctx := _resolve_call_context(expr, ctx)
	return function_registry.call_function(String(expr["name"]), args, call_ctx)

## Resolves a call's own `[Ref.]FuncName` reference prefix (if any) to the
## Node that should act as `calling_reference` for this one call -- e.g.
## `ActivatorREF.Enable` should toggle ActivatorREF, not the script's own
## owner. Real, deliberate gap: only resolves references already sitting in
## a local variable holding a live Node (e.g. set earlier via
## `Set ActivatorREF to GetActionRef`) -- a bare editor-ID/persistent-
## reference name with no such local (design doc's own "Cross-reference"
## storage tier) isn't resolved yet, since that needs a global editor-id ->
## Node registry this interpreter doesn't have wired in. Falls back to the
## caller's own context (so the call still evaluates as unimplemented/no-op
## instead of crashing) rather than guessing.
func _resolve_call_context(expr: Dictionary, ctx: ScriptExecutionContext) -> ScriptExecutionContext:
	var ref_name := String(expr.get("reference", ""))
	if ref_name == "":
		return ctx
	var resolved: Variant = ctx.player_node if ref_name.to_lower() == "player" else ctx.get_local(ref_name)
	if resolved is Node:
		var sub_ctx := ScriptExecutionContext.new(resolved)
		sub_ctx.locals = ctx.locals
		sub_ctx.action_ref = ctx.action_ref
		sub_ctx.player_node = ctx.player_node
		return sub_ctx
	return ctx
