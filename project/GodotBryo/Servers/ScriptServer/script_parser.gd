class_name ScriptParser
extends RefCounted

## Recursive-descent parser over ScriptLexer's token stream -- builds the AST
## a ScriptInterpreter tree-walks. Grammar per
## enginedocs/nv_script_interpreter_design.md's sketch. AST nodes are plain
## Dictionaries (this project's established shape for parsed/raw data --
## mesh_resolver.gd's raw geometry entries use the same convention), not a
## class hierarchy -- there's no behavior on these nodes, only shape.
##
## GECK call syntax is `[ref.]FuncName arg1 arg2 ...` with no parens or
## commas, and the data ships no arity table, so a call inside an expression
## consumes as many arguments as its function takes: KNOWN_ARITIES for the
## non-condition functions used in expressions and a few aliases, then
## ScriptConditionFunctions.ARITIES (every FNV condition function, from
## xEdit). An expression call to a function in neither table consumes no
## arguments, and any it had are parsed as whatever follows. A bare call
## STATEMENT (`FuncName arg1 arg2` on its own line) consumes every atom to
## the end of the line as an argument.
##
## An unprefixed, undeclared identifier reached as an expression PRIMARY
## (an if/set operand, or an argument to some other call -- see
## `_parse_ident_primary()`) parses as a real `{"kind": "name", "name": ...}`
## node -- a raw reference/editor-ID literal, resolved by whichever function
## actually receives it (most read it as a plain name string, like
## `ShowMessage`'s own MESG editor-ID lookup; some as a live reference
## lookup, like `IsActionRef`'s). This was originally the same "treat it as
## a phantom zero-arg call" heuristic call-head position uses, but real data
## proved that wrong for primary position specifically: `ShowMessage
## GSBrokenSMGMsg` needs the literal name `GSBrokenSMGMsg`, not a swallowed
## 0 from calling a nonexistent function named that.
const KNOWN_ARITIES := {
	"abs": 1,
	"swaptexture": 3,
	"sqrt": 1,
	"getactionref": 0,
	"getbuttonpressed": 0,
	"getcurrenttime": 0,
	"getself": 0,
	"getstage": 1,
	"getstagedone": 2,
	"getquestrunning": 1,
	"getquestcompleted": 1,
	"getactorvalue": 1,
	"getav": 1,
	"getbaseactorvalue": 1,
	"getbaseav": 1,
	"getpermanentactorvalue": 1,
	"getpermav": 1,
	"gethealthpercentage": 0,
	"getlevel": 0,
	"isactionref": 1,
	"getsecondspassed": 0,
	"gamedayspassed": 0,
	"getrandompercent": 0,
	"enable": 0,
	"disable": 0,
	"getdisabled": 0,
	"activate": 1,
	"unlock": 0,
	"placeatme": 4,
	"centeroncell": 1,
	"coc": 1,
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
var _script_name := "" # from the `scn` line, for warnings
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
		_script_name = result["script_name"]
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
		if lower == "return":
			_advance()
			return { "kind": "return" }
		if lower in _RESERVED_KEYWORDS:
			push_warning("ScriptParser: stray '%s' with no matching open block at line %d of %s -- skipped" % [tok["value"], tok["line"], _script_name])
			_advance()
			return { "kind": "noop" }
	return _parse_call_statement()

## Real, shipped data forced this: real scripts write "else if" as TWO
## words (confirmed: 182/2576 real scripts, ~7% -- e.g.
## `vMojaveExpressBoxSCRIPT`'s own real `OnLoad` block), equivalent to a
## single-word "elseif", not "else" followed by a genuinely nested `if`
## statement. Getting this wrong is not cosmetic: treating a two-word
## "else if" as a real else-block whose body happens to start with an
## unrelated `if` swallows every statement up to the NEXT real "endif" --
## which, once that inner if's own "endif" satisfies it, is however many
## blocks later the parser next stumbles on the word "endif" for any
## reason, silently merging entire unrelated Begin/End blocks into the
## wrong one (confirmed directly: a whole script's real OnActivate/
## GameMode/MenuMode content got merged into its own OnLoad body this way,
## which is why a completely unrelated real-play report -- a ShowMessage
## from what should have been an OnActivate call -- turned out to fire from
## OnLoad instead). Disambiguated here by whether "if" follows "else"
## on the SAME line (no NEWLINE token between) -- matches every real
## sample found this session; a newline before "if" still means a genuine
## nested if as the else-block's own first statement.
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
	while last_ender == "elseif" or (last_ender == "else" and _ident_is(_peek(), "if")):
		if last_ender == "else":
			_advance() # the "if" half of a two-word "else if"
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
	var call_node := _parse_call_head()
	var args := []
	while not _at_newline() and not _at_eof():
		if _peek()["kind"] == ScriptLexer.Kind.OP and _peek()["value"] == ",":
			_advance()
			continue
		args.append(_parse_expr_atom_for_call_arg())
	call_node["args"] = args
	call_node["kind"] = "call"
	return call_node

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
	var call_node := _parse_call_head()
	var lower_name := String(call_node["name"]).to_lower()
	var arity: int = KNOWN_ARITIES.get(lower_name, ScriptConditionFunctions.ARITIES.get(lower_name, -1))
	if arity == -1:
		# An identifier reached as an expression PRIMARY (an if/set operand,
		# or an argument to some other call) -- distinct from one reached as
		# a bare STATEMENT's own head (_parse_call_statement(), which always
		# treats it as a real call, correctly, since a bare statement line
		# IS call syntax). Real, confirmed data settled this: an unprefixed,
		# undeclared identifier in PRIMARY position is overwhelmingly a
		# reference/editor-ID name being passed as an argument (`ShowMessage
		# GSBrokenSMGMsg`, `IsActionRef player`, `MoveTo SomeMarkerEDID`),
		# not a nested zero-arg call -- treating it as a phantom
		# "unimplemented function" call (the previous behavior) actively
		# broke real functions like ShowMessage, which need the literal name
		# itself, not a swallowed 0. A declared local still reads its own
		# value, per the language's real variable-declaration rule (design
		# doc's Variables section).
		if String(call_node["reference"]) != "":
			return { "kind": "ref_var", "reference": call_node["reference"], "name": call_node["name"] }
		if _declared_names.has(String(call_node["name"]).to_lower()):
			return { "kind": "var", "name": call_node["name"] }
		return { "kind": "name", "name": call_node["name"] }
	# Trailing arguments may be omitted (HasPerk's second, PlaceAtMe's last
	# three): stop at the end of the line or at an operator that is not the
	# start of an argument.
	var args := []
	for i in range(arity):
		if _at_newline() or _at_eof() or _at_non_argument_operator():
			break
		args.append(_parse_primary())
	call_node["args"] = args
	call_node["kind"] = "call"
	return call_node

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

## An operator that cannot begin an argument: anything but `(` or a
## leading `-`.
func _at_non_argument_operator() -> bool:
	var tok := _peek()
	return tok["kind"] == ScriptLexer.Kind.OP and tok["value"] != "(" and tok["value"] != "-"

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
