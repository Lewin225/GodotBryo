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
func run_block(block_type: String, ctx: ScriptExecutionContext) -> void:
	for block in program["blocks"]:
		if String(block["blocktype"]).to_lower() == block_type.to_lower():
			_exec_stmts(block["stmts"], ctx)

func _exec_stmts(stmts: Array, ctx: ScriptExecutionContext) -> void:
	for stmt in stmts:
		_exec_stmt(stmt, ctx)

func _exec_stmt(stmt: Dictionary, ctx: ScriptExecutionContext) -> void:
	match String(stmt["kind"]):
		"set":
			_assign(String(stmt["target"]), _eval(stmt["expr"], ctx), ctx)
		"if":
			for branch in stmt["branches"]:
				if ScriptExecutionContext.is_truthy(_eval(branch["cond"], ctx)):
					_exec_stmts(branch["stmts"], ctx)
					return
			_exec_stmts(stmt.get("else_stmts", []), ctx)
		"call":
			_eval(stmt, ctx) # bare call statement -- evaluated for its side effect only
		"noop":
			pass # a stray reserved keyword the parser skipped -- see script_parser.gd's own doc comment on _RESERVED_KEYWORDS

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
			# literal text. Whichever function receives it (ShowMessage's
			# MESG lookup, IsActionRef's reference name, ...) decides what
			# that name actually means; the interpreter itself has no
			# global editor-id -> Node/Resource registry to resolve it
			# through, a real, deliberate gap noted elsewhere in this file.
			return String(expr["name"])
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
		"==": return 1 if _safe_equal(l, r) else 0
		"!=": return 0 if _safe_equal(l, r) else 1
		">": return 1 if _to_number(l) > _to_number(r) else 0
		"<": return 1 if _to_number(l) < _to_number(r) else 0
		">=": return 1 if _to_number(l) >= _to_number(r) else 0
		"<=": return 1 if _to_number(l) <= _to_number(r) else 0
	return null

## Real Gamebryo/GECK has exactly three value types (int/float/ref -- design
## doc's Variables section) and a real script's `==`/`!=` only ever compares
## same-category values; the real compiler would reject a type-mismatched
## comparison outright, so it never happens in valid shipped scripts. The
## only reason this interpreter can even observe a String-vs-number
## comparison is its own "name" AST node (script_parser.gd's own doc
## comment) standing in for an unresolved `ref` as a plain GDScript String
## -- a real implementation gap, not something Gamebryo itself does. GDScript's
## own `==` throws for genuinely incompatible Variant type pairs (confirmed:
## String vs int raises "Invalid operands", it does not just return false)
## instead of the C-like "different types, therefore unequal" a real runtime
## would fall back to here -- this exists to keep this interpreter matching
## that fallback rather than crashing on real, otherwise-valid scripts.
func _safe_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) == typeof(b):
		return a == b
	var a_numeric := typeof(a) == TYPE_INT or typeof(a) == TYPE_FLOAT
	var b_numeric := typeof(b) == TYPE_INT or typeof(b) == TYPE_FLOAT
	if a_numeric and b_numeric:
		return float(a) == float(b)
	return false

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
	var resolved: Variant = ctx.get_local(ref_name)
	if resolved is Node:
		var sub_ctx := ScriptExecutionContext.new(resolved)
		sub_ctx.locals = ctx.locals
		sub_ctx.action_ref = ctx.action_ref
		return sub_ctx
	return ctx
