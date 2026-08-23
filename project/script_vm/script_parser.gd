class_name ScriptParser
extends RefCounted

## Recursive-descent parser over ScriptLexer's token stream -- builds the AST
## a ScriptInterpreter tree-walks. Grammar per
## enginedocs/nv_script_interpreter_design.md's sketch. AST nodes are plain
## Dictionaries (this project's established shape for parsed/raw data --
## mesh_resolver.gd's raw geometry entries use the same convention), not a
## class hierarchy -- there's no behavior on these nodes, only shape.
##
## Real, honest scope limit (not fixed this pass -- the design doc's own
## "488 functions, not all up front" call applies here too): GECK's own call
## syntax is `[ref.]FuncName arg1 arg2 ...` with NO parens/commas required
## and no arity table shipped in the data, so a call's own argument count is
## only knowable in general by knowing the function (there are ~488 of
## them). This parser only knows the arity of the handful of functions
## KNOWN_ARITIES lists (the same small set script_function_registry.gd
## actually implements) -- an unknown function used INSIDE an expression
## (an if/set operand) is parsed as zero-arg, and a bare call STATEMENT
## (line "FuncName arg1 arg2" on its own) greedily consumes every
## identifier/number/string atom to end-of-line as an argument. Both are
## real, deliberate approximations: the statement-level case is right for
## the overwhelmingly common "one call per line" real-script shape; the
## expression-level case can misparse a real unknown function that takes
## arguments inside an if/set (logged via push_warning when it happens, not
## silently wrong).
##
## A related, real consequence of the same "undeclared bare identifier ==
## function call" heuristic (see `_parse_ident_primary()`): a bare
## reference/editor-ID literal used as an ARGUMENT (e.g. `MoveTo
## SomeMarkerEDID`) is indistinguishable, at parse time, from a genuine
## zero-arg call to an unimplemented function -- confirmed against a real
## script this session (`VLCSafetyTrigger01SCRIPT`'s own
## `VHDLegateCampGateDestinationMarker` marker argument logs as an
## "unimplemented function" the same way an actual missing function would).
## Harmless for this milestone (still evaluates to 0, still doesn't crash),
## but real -- disambiguating call-head position from argument position
## (or resolving via SCRO, once that's wired in) is a follow-up, not fixed
## here.
const KNOWN_ARITIES := {
	"getactionref": 0,
	"isactionref": 1,
	"getsecondspassed": 0,
	"gamedayspassed": 0,
	"getrandompercent": 0,
	"enable": 0,
	"disable": 0,
	"getdisabled": 0,
	"activate": 1,
	"unlock": 0,
}

const _DECL_TYPES := ["int", "float", "ref", "short", "long"]
const _BLOCK_ENDERS := ["end"]
const _IF_ENDERS := ["elseif", "else", "endif"]
const _BINOP_PRECEDENCE := {
	"||": 1,
	"&&": 2,
	"==": 3, "!=": 3, ">": 3, "<": 3, ">=": 3, "<=": 3,
	"+": 4, "-": 4,
	"*": 5, "/": 5, "%": 5,
}

var _tokens: Array
var _pos: int = 0
var _declared_names: Dictionary = {} # lowercased local variable name -> true, accumulated as declarations are parsed

func _init(tokens: Array) -> void:
	_tokens = tokens

func parse() -> Dictionary:
	var result := {
		"script_name": "",
		"declarations": [],
		"blocks": [],
	}
	_skip_newlines()
	if _ident_is(_peek(), "scn") or _ident_is(_peek(), "scriptname"):
		_advance()
		result["script_name"] = str(_advance()["value"])
	_skip_newlines()

	while not _at_eof():
		var tok: Dictionary = _peek()
		if tok["kind"] != ScriptLexer.Kind.IDENT:
			_advance() # stray token at top level -- skip rather than abort the whole parse
			continue
		var lower := str(tok["value"]).to_lower()
		if lower in _DECL_TYPES:
			result["declarations"].append(_parse_declaration())
		elif lower == "begin":
			result["blocks"].append(_parse_block())
		else:
			_advance() # unrecognized top-level line -- skip, don't abort the parse
		_skip_newlines()
	return result

func _parse_declaration() -> Dictionary:
	var type_name := str(_advance()["value"]).to_lower()
	var var_name := str(_advance()["value"])
	_declared_names[var_name.to_lower()] = true
	_skip_to_newline()
	return { "type": type_name, "name": var_name }

func _parse_block() -> Dictionary:
	_advance() # "begin"
	var blocktype := str(_advance()["value"])
	var params := []
	while not _at_newline() and not _at_eof():
		params.append(_advance()["value"])
	_skip_newlines()
	var stmts := _parse_statements_until(_BLOCK_ENDERS)
	return { "blocktype": blocktype, "params": params, "stmts": stmts }

## Parses statements until an IDENT matching one of `enders` (case
## insensitive) is found at the START of a line; consumes that ender token
## too. Returns the statement list.
func _parse_statements_until(enders: Array) -> Array:
	var stmts := []
	_skip_newlines()
	while not _at_eof():
		var tok: Dictionary = _peek()
		if tok["kind"] == ScriptLexer.Kind.IDENT and str(tok["value"]).to_lower() in enders:
			_advance()
			break
		stmts.append(_parse_statement())
		_skip_newlines()
	return stmts

## Real, shipped data forced this: reserved block-structure keywords
## (endif/elseif/else/end) must never fall through to being parsed as a
## bare call statement, even when they show up somewhere no open
## if/elseif/begin actually expects one. Confirmed against
## GSBrokenSMGScript's own real GameMode block -- one `if`, two `endif`s
## (a real authoring mismatch that evidently still compiled and shipped;
## SCDA is deliberately never decoded here, so there's no way to confirm
## what the original compiler actually did with the extra one). Without
## this, the stray "endif" parsed as a zero-arg call to a function named
## "endif", which then reports as a real "unimplemented function" --
## misleading (there's no such function) rather than what it actually is:
## a stray structural token. Logged once per parse, not silently dropped.
const _RESERVED_KEYWORDS := ["endif", "elseif", "else", "end"]

func _parse_statement() -> Dictionary:
	var tok: Dictionary = _peek()
	if tok["kind"] == ScriptLexer.Kind.IDENT:
		var lower := str(tok["value"]).to_lower()
		if lower == "if":
			return _parse_if()
		if lower == "set":
			return _parse_set()
		if lower in _RESERVED_KEYWORDS:
			push_warning("ScriptParser: stray '%s' with no matching open block at line %d -- skipped" % [tok["value"], tok["line"]])
			_advance()
			return { "kind": "noop" }
	return _parse_call_statement()

func _parse_if() -> Dictionary:
	var branches := []
	var else_stmts: Array = []
	_advance() # "if"
	var cond := _parse_expr()
	_skip_newlines()
	var stmts := _parse_statements_until(_IF_ENDERS)
	branches.append({ "cond": cond, "stmts": stmts })
	# _parse_statements_until() consumed whichever ender matched; re-inspect
	# the token just before that to know which branch we're continuing --
	# simplest robust way given the shared ender list is to look back one.
	var last_ender := str(_tokens[_pos - 1]["value"]).to_lower() if _pos > 0 else ""
	while last_ender == "elseif":
		var elseif_cond := _parse_expr()
		_skip_newlines()
		var elseif_stmts := _parse_statements_until(_IF_ENDERS)
		branches.append({ "cond": elseif_cond, "stmts": elseif_stmts })
		last_ender = str(_tokens[_pos - 1]["value"]).to_lower() if _pos > 0 else ""
	if last_ender == "else":
		_skip_newlines()
		else_stmts = _parse_statements_until(["endif"])
	return { "kind": "if", "branches": branches, "else_stmts": else_stmts }

func _parse_set() -> Dictionary:
	_advance() # "set"
	var target := _parse_dotted_name()
	if _ident_is(_peek(), "to"):
		_advance()
	var expr := _parse_expr()
	return { "kind": "set", "target": target, "expr": expr }

## A bare call statement: `[Ref.]FuncName arg1 arg2 ...` to end of line.
## Real per-line shape (see this file's own top doc comment for the arity
## caveat).
func _parse_call_statement() -> Dictionary:
	var call := _parse_call_head()
	var args := []
	while not _at_newline() and not _at_eof():
		if _peek()["kind"] == ScriptLexer.Kind.OP and _peek()["value"] == ",":
			_advance()
			continue
		args.append(_parse_expr_atom_for_call_arg())
	call["args"] = args
	call["kind"] = "call"
	return call

## Parses `[Ident "."] Ident` -- either a plain name or a reference-prefixed
## one -- returning { "reference": String or "", "name": String }.
func _parse_call_head() -> Dictionary:
	var first := str(_advance()["value"])
	if _peek()["kind"] == ScriptLexer.Kind.OP and _peek()["value"] == ".":
		_advance()
		var name := str(_advance()["value"])
		return { "reference": first, "name": name }
	return { "reference": "", "name": first }

func _parse_dotted_name() -> String:
	var name := str(_advance()["value"])
	while _peek()["kind"] == ScriptLexer.Kind.OP and _peek()["value"] == ".":
		_advance()
		name += "." + str(_advance()["value"])
	return name

## A single argument atom for a greedily-consumed call-statement argument
## list -- a literal, variable name, or (rare in practice) a parenthesized
## sub-expression. Not a full expression parse: real call-statement args
## are almost always atoms, and treating them as full expressions would
## swallow a following call on the same conceptual "line of atoms" the
## wrong way.
func _parse_expr_atom_for_call_arg() -> Dictionary:
	return _parse_primary()

## Full expression parse (precedence climbing) -- used for if/elseif
## conditions and the right-hand side of `set ... to`, where operators are
## real and need real precedence, per this file's own top doc comment.
func _parse_expr(min_prec: int = 0) -> Dictionary:
	var left := _parse_unary()
	while true:
		var tok: Dictionary = _peek()
		if tok["kind"] != ScriptLexer.Kind.OP or not _BINOP_PRECEDENCE.has(tok["value"]):
			break
		var prec: int = _BINOP_PRECEDENCE[tok["value"]]
		if prec < min_prec:
			break
		var op := str(_advance()["value"])
		var right := _parse_expr(prec + 1)
		left = { "kind": "binop", "op": op, "left": left, "right": right }
	return left

func _parse_unary() -> Dictionary:
	if _peek()["kind"] == ScriptLexer.Kind.OP and _peek()["value"] == "-":
		_advance()
		return { "kind": "unary", "op": "-", "operand": _parse_unary() }
	return _parse_primary()

func _parse_primary() -> Dictionary:
	var tok: Dictionary = _peek()
	if tok["kind"] == ScriptLexer.Kind.NUMBER:
		_advance()
		return { "kind": "literal", "value": tok["value"] }
	if tok["kind"] == ScriptLexer.Kind.STRING:
		_advance()
		return { "kind": "literal", "value": tok["value"] }
	if tok["kind"] == ScriptLexer.Kind.OP and tok["value"] == "(":
		_advance()
		var inner := _parse_expr()
		if _peek()["kind"] == ScriptLexer.Kind.OP and _peek()["value"] == ")":
			_advance()
		return inner
	if tok["kind"] == ScriptLexer.Kind.IDENT:
		return _parse_ident_primary()
	# Unrecognized primary (e.g. a stray operator/newline reached via a
	# malformed real script) -- return a zero literal rather than crash the
	# whole parse; the interpreter's own boolean coercion treats 0 as
	# false, matching the language's real "silently stop" failure mode
	# (see nv_script_interpreter_design.md's `ref` safety-check section) --
	# consistent behavior for a different kind of malformed input.
	_advance()
	return { "kind": "literal", "value": 0 }

func _parse_ident_primary() -> Dictionary:
	var call := _parse_call_head()
	var lower_name := String(call["name"]).to_lower()
	var arity: int = KNOWN_ARITIES.get(lower_name, -1)
	if arity == -1:
		# Unknown function used inside an expression -- see this file's own
		# top doc comment. GECK requires every variable to be declared
		# before use (real language rule, design doc's Variables section),
		# so an unprefixed identifier that ISN'T one of this script's own
		# declared locals can only be a function call the real compiler
		# validated at build time -- treated as a real, zero-arg
		# unimplemented call (logged, evaluates to 0) rather than a bare
		# variable read (which would silently and wrongly resolve to null
		# instead of surfacing that the function isn't implemented yet).
		if String(call["reference"]) == "" and _declared_names.has(String(call["name"]).to_lower()):
			return { "kind": "var", "name": call["name"] }
		call["args"] = []
		call["kind"] = "call"
		return call
	var args := []
	for i in range(arity):
		if _at_newline() or _at_eof():
			push_warning("ScriptParser: expected %d arg(s) for %s, ran out of tokens" % [arity, call["name"]])
			break
		args.append(_parse_primary())
	call["args"] = args
	call["kind"] = "call"
	return call

func _peek(offset: int = 0) -> Dictionary:
	var i: int = _pos + offset
	if i >= _tokens.size():
		return _tokens[_tokens.size() - 1] # EOF_ sentinel
	return _tokens[i]

func _advance() -> Dictionary:
	var tok: Dictionary = _peek()
	if tok["kind"] != ScriptLexer.Kind.EOF_:
		_pos += 1
	return tok

func _at_eof() -> bool:
	return _peek()["kind"] == ScriptLexer.Kind.EOF_

func _at_newline() -> bool:
	return _peek()["kind"] == ScriptLexer.Kind.NEWLINE or _at_eof()

func _skip_newlines() -> void:
	while _peek()["kind"] == ScriptLexer.Kind.NEWLINE:
		_advance()

func _skip_to_newline() -> void:
	while not _at_newline():
		_advance()

func _ident_is(tok: Dictionary, text: String) -> bool:
	return tok["kind"] == ScriptLexer.Kind.IDENT and str(tok["value"]).to_lower() == text
