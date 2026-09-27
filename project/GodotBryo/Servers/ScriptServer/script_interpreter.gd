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
var _declared: Dictionary = {} # lowercased names of the script's declared variables

func _init(parsed_program: Dictionary, registry: ScriptFunctionRegistry) -> void:
	program = parsed_program
	function_registry = registry
	for declaration in program.get("declarations", []):
		_declared[String(declaration["name"]).to_lower()] = true

func has_block(block_type: String) -> bool:
	for block in program["blocks"]:
		if String(block["blocktype"]).to_lower() == block_type.to_lower():
			return true
	return false

## Whether a `block_type` block would run for `subject` (see run_block).
func has_block_for(block_type: String, ctx: ScriptExecutionContext, subject: Variant = null) -> bool:
	for block in program["blocks"]:
		if String(block["blocktype"]).to_lower() == block_type.to_lower() and _block_accepts(block, ctx, subject):
			return true
	return false

## Runs every `block_type` block (case-insensitive) that accepts `subject`.
## A block without a parameter always runs. A block with one runs only when
## the parameter names `subject`: `Begin OnActivate Player` runs when the
## player's reference is the activator, `Begin MenuMode 1001` when subject is
## 1001.
func run_block(block_type: String, ctx: ScriptExecutionContext, subject: Variant = null) -> Variant:
	var result: Variant = null
	for block in program["blocks"]:
		if String(block["blocktype"]).to_lower() == block_type.to_lower() and _block_accepts(block, ctx, subject):
			result = _exec_stmts(block["stmts"], ctx)
	return result

func _block_accepts(block: Dictionary, ctx: ScriptExecutionContext, subject: Variant) -> bool:
	var params: Array = block.get("params", [])
	if params.is_empty():
		return true
	if subject == null:
		return false
	var param: Variant = params[0]
	if param is String:
		var named := ctx.resolve_reference_name(param)
		return named != null and named == subject
	return ScriptExecutionContext.safe_equal(param, subject)

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
		# A name the script does not declare may be a global variable.
		var server = function_registry.script_server
		if _declared.has(target.to_lower()) or ctx.has_local(target) or server == null or not server.globals.set_global(target, value):
			ctx.set_local(target, value)
		return
	# `OtherREF.var`: a variable of another reference's script.
	var dot := target.find(".")
	var instance := _instance_of(target.substr(0, dot), ctx)
	if instance != null:
		instance.set_local(target.substr(dot + 1), value)
	else:
		push_warning("ScriptInterpreter: '%s' names no reference or quest with a script, assignment dropped" % target)

func _eval(expr: Dictionary, ctx: ScriptExecutionContext) -> Variant:
	match String(expr["kind"]):
		"literal":
			return expr["value"]
		"var":
			return ctx.get_local(String(expr["name"]))
		"name":
			# A bare name in source: a reference editor ID, a global variable,
			# a MESG editor ID for ShowMessage, and so on. References and
			# globals resolve to their value; the rest stay as text for the
			# called function.
			var raw_name := String(expr["name"])
			var named := ctx.resolve_reference_name(raw_name)
			if named != null:
				return named
			var server = function_registry.script_server
			var global: Variant = server.globals.get_global(raw_name) if server != null else null
			return global if global != null else raw_name
		"ref_var":
			var instance := _instance_of(String(expr["reference"]), ctx)
			var value: Variant = instance.get_local(String(expr["name"])) if instance != null else null
			return value if value != null else 0
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

## Resolves a call's `[Ref.]FuncName` prefix to the context the call runs
## in: `ActivatorREF.Enable` acts on ActivatorREF, not on the script's own
## reference. A prefix that names no reference leaves the call on the
## caller's own context.
func _resolve_call_context(expr: Dictionary, ctx: ScriptExecutionContext) -> ScriptExecutionContext:
	var ref_name := String(expr.get("reference", ""))
	if ref_name == "":
		return ctx
	var resolved := _resolve_reference(ref_name, ctx)
	return ctx.with_subject(resolved) if resolved != null else ctx

## A reference prefix: a `ref` local of this script, `player`, or a placed
## reference's editor ID.
func _resolve_reference(ref_name: String, ctx: ScriptExecutionContext) -> EsmReference:
	var local: Variant = ctx.get_local(ref_name) if ctx.has_local(ref_name) else null
	if local is EsmReference:
		return local
	return ctx.resolve_reference_name(ref_name)

## The ScriptInstance behind `ref_name.var`: the named reference's script, or
## else the named quest's script. Null when neither exists.
func _instance_of(ref_name: String, ctx: ScriptExecutionContext) -> ScriptInstance:
	var server = function_registry.script_server
	if server == null:
		return null
	var ref := _resolve_reference(ref_name, ctx)
	if ref != null:
		return server.get_script_instance(ref)
	var esm_server := EsmReference.get_esm_server()
	if esm_server == null or not esm_server.is_ready():
		return null
	return server.get_quest_instance(esm_server.find_quest_by_editor_id(ref_name))
