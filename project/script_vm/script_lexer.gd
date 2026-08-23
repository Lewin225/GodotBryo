class_name ScriptLexer
extends RefCounted

## Tokenizes a real SCTX source string (GECK script language) --
## enginedocs/nv_script_interpreter_design.md's grammar sketch. Real
## samples confirmed this session: statements are newline-separated (a
## trailing `;` is common but optional), keywords are case-insensitive
## ("Set"/"set"/"SET" all appear in real scripts), identifiers may contain
## a leading letter then letters/digits/underscore, and `.` chains a
## reference prefix onto a function call (`ActivatorREF.MoveTo Marker`).
##
## Block comments (`/* */`) are xNVSE 6.2.1+, not vanilla -- only `;` to
## end-of-line comments are handled here, per the design doc's own grammar
## sketch and explicit non-goals section.

enum Kind { IDENT, NUMBER, STRING, OP, NEWLINE, EOF_ }

const _TWO_CHAR_OPS := ["==", "!=", ">=", "<=", "&&", "||", ":="]
const _ONE_CHAR_OPS := ["+", "-", "*", "/", "%", "=", "<", ">", "(", ")", ",", "."]

var _text: String
var _pos: int = 0
var _line: int = 1
var _len: int = 0

func _init(source_text: String) -> void:
	_text = source_text
	_len = _text.length()

## Returns an Array of Dictionaries: { "kind": Kind, "value": Variant, "line": int }.
## Always ends with one Kind.EOF_ token.
func tokenize() -> Array:
	var tokens := []
	while true:
		var tok := _next_token()
		tokens.append(tok)
		if tok["kind"] == Kind.EOF_:
			break
	return tokens

func _peek_char() -> String:
	return _text[_pos] if _pos < _len else ""

func _next_token() -> Dictionary:
	_skip_whitespace_and_comments()
	if _pos >= _len:
		return { "kind": Kind.EOF_, "value": "", "line": _line }

	var c := _peek_char()
	var start_line := _line

	if c == "\n":
		_pos += 1
		_line += 1
		return { "kind": Kind.NEWLINE, "value": "\n", "line": start_line }

	if c == "\"":
		return _read_string()

	if c.is_valid_int() or (c == "." and _pos + 1 < _len and _text[_pos + 1].is_valid_int()):
		return _read_number()

	if c.to_upper() != c.to_lower() or c == "_":
		return _read_ident()

	for op in _TWO_CHAR_OPS:
		if _pos + op.length() <= _len and _text.substr(_pos, op.length()) == op:
			_pos += op.length()
			return { "kind": Kind.OP, "value": op, "line": start_line }

	if c in _ONE_CHAR_OPS:
		_pos += 1
		return { "kind": Kind.OP, "value": c, "line": start_line }

	# Unrecognized character -- skip it rather than hard-fail the whole
	# script over one stray byte (a real script that trips this should be
	# investigated, not silently misparsed downstream, so this is left
	# visible via push_warning rather than silently dropped).
	push_warning("ScriptLexer: skipping unrecognized character '%s' at line %d" % [c, start_line])
	_pos += 1
	return _next_token()

func _skip_whitespace_and_comments() -> void:
	while _pos < _len:
		var c := _peek_char()
		if c == " " or c == "\t" or c == "\r":
			_pos += 1
		elif c == ";":
			while _pos < _len and _text[_pos] != "\n":
				_pos += 1
		else:
			break

func _read_string() -> Dictionary:
	var start_line := _line
	_pos += 1 # opening quote
	var out := ""
	while _pos < _len and _text[_pos] != "\"":
		if _text[_pos] == "\n":
			_line += 1
		out += _text[_pos]
		_pos += 1
	_pos += 1 # closing quote, if present -- an unterminated string just runs to EOF, no crash
	return { "kind": Kind.STRING, "value": out, "line": start_line }

func _read_number() -> Dictionary:
	var start_line := _line
	var start := _pos
	var is_float := false
	while _pos < _len and (_text[_pos].is_valid_int() or _text[_pos] == "."):
		if _text[_pos] == ".":
			is_float = true
		_pos += 1
	var raw := _text.substr(start, _pos - start)
	var value: Variant = float(raw) if is_float else int(raw)
	return { "kind": Kind.NUMBER, "value": value, "line": start_line }

func _read_ident() -> Dictionary:
	var start_line := _line
	var start := _pos
	while _pos < _len:
		var c := _text[_pos]
		if c.to_upper() != c.to_lower() or c == "_" or c.is_valid_int():
			_pos += 1
		else:
			break
	var raw := _text.substr(start, _pos - start)
	return { "kind": Kind.IDENT, "value": raw, "line": start_line }
