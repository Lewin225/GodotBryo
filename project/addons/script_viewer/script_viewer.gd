@tool
extends Control

## Editor-only, read-only script inspector -- browse any real SCPT by
## editor ID, see its actual GECK source text with every function call
## color-coded by whether script_function_registry.gd implements it, and
## Ctrl+Click an implemented call to jump straight to its registration in
## the editor's own script view (EditorInterface.edit_script()). Docked as
## a real EditorPlugin main-screen tab (see plugin.gd's own doc comment for
## why a plain @tool scene can't do this).
##
## Deliberately never writes anything -- no save, no edit. `_source_display`
## (a CodeEdit) is set non-editable; the real source is read straight from
## the ESM every time a script is selected, and nothing here could touch
## FalloutNV.esm even if it tried.
##
## CodeEdit chosen over RichTextLabel specifically for its built-in
## "Ctrl+Click a symbol to look it up" support (symbol_lookup_on_click) --
## the exact Ctrl+Click-to-navigate UX this tool needs, already handling
## word-boundary detection, hover-underline feedback, and the Ctrl gating
## itself, instead of hand-rolling all three around RichTextLabel's
## meta_clicked. Highlighting uses a CodeHighlighter with per-script
## keyword colors (re-populated on every selection) rather than manual
## BBCode spans -- simpler, and avoids needing exact source offsets at all.
##
## Reuses the exact same lex/parse/registry pipeline
## project/script_vm/script_engine.gd runs at actual game time -- this
## tool's highlighting is only ever as correct (or as wrong) as the real
## interpreter, by construction, not a parallel bespoke text scan that
## could silently drift from what the game actually does.

const ESM_PATH := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/FalloutNV.esm"
const REGISTRY_SCRIPT_PATH := "res://script_vm/script_function_registry.gd"

const COLOR_KNOWN := Color("#7ec699") # implemented -- registered in script_function_registry.gd
const COLOR_UNKNOWN := Color("#e06c75") # real, per script_function_registry.gd's own doc comment: evaluates to 0/false at runtime, not a guess
const COLOR_NUMBER := Color("c0c13eff") # warm, high-contrast number color for the dark editor theme
const COLOR_FUNCTION := Color("#61afef")
const COLOR_MEMBER_VARIABLE := Color("#e5c07b")
const COLOR_SYMBOL := Color("#c678dd")

@onready var _search_edit: LineEdit = $HSplit/Left/SearchEdit
@onready var _script_list: ItemList = $HSplit/Left/ScriptList
@onready var _summary_label: Label = $HSplit/Right/SummaryLabel
@onready var _source_display: CodeEdit = $HSplit/Right/SourceDisplay
@onready var _status_label: Label = $HSplit/Right/StatusLabel

var _esm: EsmReader
var _function_registry: ScriptFunctionRegistry
var _highlighter: CodeHighlighter
var _all_scripts: Array = [] # [{ "form_id": int, "editor_id": String }], sorted by editor_id
var _visible_indices: PackedInt32Array = [] # indices into _all_scripts currently shown in _script_list
var _found_calls_lower: Dictionary = {} # lowercased call name -> bool known, rebuilt fresh on every _show_script()

func _ready() -> void:
	if not Engine.is_editor_hint():
		return # editor tooling only -- see this file's own doc comment
	_function_registry = ScriptFunctionRegistry.new()
	_highlighter = CodeHighlighter.new()
	_highlighter.number_color = COLOR_NUMBER
	_highlighter.function_color = COLOR_FUNCTION
	_highlighter.member_variable_color = COLOR_MEMBER_VARIABLE
	_highlighter.symbol_color = COLOR_SYMBOL
	_source_display.syntax_highlighter = _highlighter
	_source_display.editable = false
	_source_display.gutters_draw_line_numbers = true
	_source_display.set_symbol_lookup_on_click_enabled(true)
	_search_edit.text_changed.connect(_on_search_changed)
	_script_list.item_selected.connect(_on_script_selected)
	_source_display.symbol_validate.connect(_on_symbol_validate)
	_source_display.symbol_lookup.connect(_on_symbol_lookup)
	_load_script_list()

func _load_script_list() -> void:
	_esm = EsmReader.new()
	if not _esm.open(ESM_PATH):
		_status_label.text = "Failed to open ESM: %s" % _esm.get_last_error()
		return
	var form_ids: PackedInt64Array = _esm.get_all_script_form_ids()
	for form_id in form_ids:
		var data: Dictionary = _esm.get_script_data(int(form_id))
		if data.is_empty():
			continue
		_all_scripts.append({ "form_id": int(form_id), "editor_id": String(data.get("editor_id", "")) })
	_all_scripts.sort_custom(func(a, b): return a["editor_id"] < b["editor_id"])
	_status_label.text = "%d real scripts loaded from FalloutNV.esm" % _all_scripts.size()
	_refresh_list("")

func _on_search_changed(text: String) -> void:
	_refresh_list(text)

func _refresh_list(filter_text: String) -> void:
	_script_list.clear()
	_visible_indices.clear()
	var lower_filter := filter_text.to_lower()
	for i in range(_all_scripts.size()):
		var editor_id: String = _all_scripts[i]["editor_id"]
		if lower_filter != "" and editor_id.to_lower().find(lower_filter) == -1:
			continue
		_script_list.add_item(editor_id)
		_visible_indices.append(i)

func _on_script_selected(list_index: int) -> void:
	if list_index < 0 or list_index >= _visible_indices.size():
		return
	var entry: Dictionary = _all_scripts[_visible_indices[list_index]]
	_show_script(int(entry["form_id"]), String(entry["editor_id"]))

func _show_script(form_id: int, editor_id: String) -> void:
	var data: Dictionary = _esm.get_script_data(form_id)
	if data.is_empty():
		_status_label.text = "Could not resolve script data for 0x%X" % form_id
		return
	var source := String(data["source_text"])
	var tokens := ScriptLexer.new(source).tokenize()
	var program := ScriptParser.new(tokens).parse()

	var block_names := []
	for block in program["blocks"]:
		block_names.append(String(block["blocktype"]))
	_summary_label.text = "%s   (0x%X)   %d locals   blocks: %s" % [
		editor_id, form_id, program["declarations"].size(),
		", ".join(block_names) if not block_names.is_empty() else "(none)",
	]

	# casing_variants: the literal text as it appears at each call site (a
	# script can call the same function with different casing at different
	# sites -- real, since the language is case-insensitive) -> bool known.
	# CodeHighlighter's own keyword matching needs every real casing
	# variant registered, since it isn't case-insensitive itself.
	var casing_variants := {}
	_found_calls_lower.clear()
	for block in program["blocks"]:
		_collect_call_names(block["stmts"], casing_variants)
	for name in casing_variants:
		_found_calls_lower[String(name).to_lower()] = casing_variants[name]

	_highlighter.clear_keyword_colors()
	for name in casing_variants:
		_highlighter.add_keyword_color(name, COLOR_KNOWN if casing_variants[name] else COLOR_UNKNOWN)

	_source_display.text = source
	var known_count: int = casing_variants.values().count(true)
	_status_label.text = "%d distinct calls found (%d implemented, %d not) -- Ctrl+Click an implemented one to jump to its code" % [
		casing_variants.size(), known_count, casing_variants.size() - known_count,
	]

func _collect_call_names(stmts: Array, out: Dictionary) -> void:
	for stmt in stmts:
		match String(stmt["kind"]):
			"set":
				_collect_call_names_in_expr(stmt["expr"], out)
			"if":
				for branch in stmt["branches"]:
					_collect_call_names_in_expr(branch["cond"], out)
					_collect_call_names(branch["stmts"], out)
				_collect_call_names(stmt.get("else_stmts", []), out)
			"call":
				_collect_call_name(stmt, out)
				for a in stmt["args"]:
					_collect_call_names_in_expr(a, out)

func _collect_call_names_in_expr(expr: Dictionary, out: Dictionary) -> void:
	match String(expr["kind"]):
		"binop":
			_collect_call_names_in_expr(expr["left"], out)
			_collect_call_names_in_expr(expr["right"], out)
		"unary":
			_collect_call_names_in_expr(expr["operand"], out)
		"call":
			_collect_call_name(expr, out)
			for a in expr["args"]:
				_collect_call_names_in_expr(a, out)

func _collect_call_name(call_expr: Dictionary, out: Dictionary) -> void:
	var name: String = call_expr["name"]
	out[name] = _function_registry.is_registered(name)

## CodeEdit's own built-in symbol-lookup flow: while Ctrl is held and the
## mouse hovers a word, this is asked whether that word is a valid,
## clickable symbol (controls the hover-underline) -- gated on it actually
## being one of this specific script's own real function calls, not just
## any word that happens to match a known function name elsewhere (a local
## variable coincidentally named the same as a real function, say).
func _on_symbol_validate(symbol: String) -> void:
	_source_display.set_symbol_lookup_word_as_valid(_found_calls_lower.has(symbol.to_lower()))

func _on_symbol_lookup(symbol: String, _line: int, _column: int) -> void:
	var lower := symbol.to_lower()
	if not _found_calls_lower.has(lower):
		return
	if not _found_calls_lower[lower]:
		_status_label.text = "%s is not implemented -- evaluates to 0/false at runtime" % symbol
		return
	_jump_to_registration(symbol)

## "if possible" per this tool's own design goal -- EditorInterface is only
## meaningful when this scene is actually open inside the running editor
## (Engine.is_editor_hint() already gates _ready() itself, so reaching here
## at all implies that's true), and the registration line is found by a
## plain text search of the real file, not any editor-side symbol index --
## simple, but correct for this file's own real shape (one register() call
## per line).
func _jump_to_registration(func_name: String) -> void:
	var line := _find_registration_line(func_name)
	if line == -1:
		_status_label.text = "Could not find '%s' registration in script_function_registry.gd (renamed since this tool was built?)" % func_name
		return
	var script: Script = load(REGISTRY_SCRIPT_PATH)
	EditorInterface.edit_script(script, line, 0, true)
	_status_label.text = "Jumped to '%s' in script_function_registry.gd:%d" % [func_name, line + 1]

func _find_registration_line(func_name: String) -> int:
	var file := FileAccess.open(REGISTRY_SCRIPT_PATH, FileAccess.READ)
	if file == null:
		return -1
	var needle := "register(\"%s\"" % func_name
	var line_index := 0
	while not file.eof_reached():
		var line := file.get_line()
		if line.to_lower().find(needle.to_lower()) != -1:
			file.close()
			return line_index
		line_index += 1
	file.close()
	return -1
