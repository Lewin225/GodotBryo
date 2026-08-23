@tool
extends Control

## Editor-only, read-only script inspector -- browse any real SCPT by
## editor ID, see its actual GECK source text with every function call
## color-coded by whether script_function_registry.gd implements it, and
## Ctrl+Click an implemented call to jump straight to its registration in
## the editor's own script view (EditorInterface.edit_script()). Same
## "open the scene, no Play needed" convention as nif_viewer.gd/
## interior_viewer.gd -- this Control renders and is fully interactive in
## the editor's own 2D viewport the moment the scene is open.
##
## Deliberately never writes anything -- no save, no edit, not even of the
## displayed RichTextLabel's own text. The real source is read straight
## from the ESM every time a script is selected; nothing here could touch
## FalloutNV.esm even if it tried.
##
## Reuses the exact same lex/parse/registry pipeline
## project/script_vm/script_engine.gd runs at actual game time -- this
## tool's highlighting is only ever as correct (or as wrong) as the real
## interpreter, by construction, not a parallel bespoke text scan that
## could silently drift from what the game actually does.

const ESM_PATH := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/FalloutNV.esm"
const REGISTRY_SCRIPT_PATH := "res://script_vm/script_function_registry.gd"

const COLOR_KNOWN := "#7ec699" # implemented -- registered in script_function_registry.gd
const COLOR_UNKNOWN := "#e06c75" # real, per script_function_registry.gd's own doc comment: evaluates to 0/false at runtime, not a guess

@onready var _search_edit: LineEdit = $HSplit/Left/SearchEdit
@onready var _script_list: ItemList = $HSplit/Left/ScriptList
@onready var _summary_label: Label = $HSplit/Right/SummaryLabel
@onready var _source_display: RichTextLabel = $HSplit/Right/SourceDisplay
@onready var _status_label: Label = $HSplit/Right/StatusLabel

var _esm: EsmReader
var _function_registry: ScriptFunctionRegistry
var _all_scripts: Array = [] # [{ "form_id": int, "editor_id": String }], sorted by editor_id
var _visible_indices: PackedInt32Array = [] # indices into _all_scripts currently shown in _script_list

func _ready() -> void:
	if not Engine.is_editor_hint():
		return # editor tooling only -- see this file's own doc comment
	_function_registry = ScriptFunctionRegistry.new()
	_search_edit.text_changed.connect(_on_search_changed)
	_script_list.item_selected.connect(_on_script_selected)
	_source_display.meta_clicked.connect(_on_meta_clicked)
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

	var spans := [] # { "start": int, "end": int, "name": String, "known": bool }, sorted, non-overlapping by construction (parser never nests two calls at the same source span)
	for block in program["blocks"]:
		_collect_call_spans(block["stmts"], spans)
	spans.sort_custom(func(a, b): return a["start"] < b["start"])

	_source_display.text = _build_bbcode(source, spans)
	_status_label.text = "%d function calls found (%d implemented, %d not) -- Ctrl+Click an implemented one to jump to its code" % [
		spans.size(), spans.filter(func(s): return s["known"]).size(), spans.filter(func(s): return not s["known"]).size(),
	]

func _collect_call_spans(stmts: Array, out: Array) -> void:
	for stmt in stmts:
		match String(stmt["kind"]):
			"set":
				_collect_call_spans_in_expr(stmt["expr"], out)
			"if":
				for branch in stmt["branches"]:
					_collect_call_spans_in_expr(branch["cond"], out)
					_collect_call_spans(branch["stmts"], out)
				_collect_call_spans(stmt.get("else_stmts", []), out)
			"call":
				_collect_call_span(stmt, out)
				for a in stmt["args"]:
					_collect_call_spans_in_expr(a, out)

func _collect_call_spans_in_expr(expr: Dictionary, out: Array) -> void:
	match String(expr["kind"]):
		"binop":
			_collect_call_spans_in_expr(expr["left"], out)
			_collect_call_spans_in_expr(expr["right"], out)
		"unary":
			_collect_call_spans_in_expr(expr["operand"], out)
		"call":
			_collect_call_span(expr, out)
			for a in expr["args"]:
				_collect_call_spans_in_expr(a, out)

func _collect_call_span(call_expr: Dictionary, out: Array) -> void:
	if not call_expr.has("name_start"):
		return # defensive -- every real "call" node has this; see script_parser.gd's own doc comment
	var name: String = call_expr["name"]
	out.append({
		"start": int(call_expr["name_start"]),
		"end": int(call_expr["name_end"]),
		"name": name,
		"known": _function_registry.is_registered(name),
	})

## Renders `source` as BBCode, wrapping each call-name span in a color +
## [url] tag (meta payload: "known:<name>" or "unknown:<name>") so
## meta_clicked can tell which one was clicked and whether it's worth
## trying to navigate to. Everything else is plain, BBCode-escaped text.
func _build_bbcode(source: String, spans: Array) -> String:
	var out := ""
	var cursor := 0
	for span in spans:
		var start: int = span["start"]
		var end: int = span["end"]
		if start < cursor:
			continue # overlap guard -- shouldn't happen, but never emit malformed BBCode over it
		out += _bbcode_escape(source.substr(cursor, start - cursor))
		var color: String = COLOR_KNOWN if span["known"] else COLOR_UNKNOWN
		var tag: String = "known" if span["known"] else "unknown"
		out += "[color=%s][url=%s:%s]%s[/url][/color]" % [color, tag, span["name"], _bbcode_escape(source.substr(start, end - start))]
		cursor = end
	out += _bbcode_escape(source.substr(cursor))
	return out

func _bbcode_escape(text: String) -> String:
	return text.replace("[", "[lb]")

func _on_meta_clicked(meta: Variant) -> void:
	var meta_str := String(meta)
	var sep := meta_str.find(":")
	if sep == -1:
		return
	var kind := meta_str.substr(0, sep)
	var func_name := meta_str.substr(sep + 1)

	if not Input.is_key_pressed(KEY_CTRL):
		_status_label.text = "%s -- %s (Ctrl+Click to jump to its code)" % [
			func_name, "implemented in script_function_registry.gd" if kind == "known" else "NOT implemented -- evaluates to 0/false at runtime",
		]
		return

	if kind != "known":
		_status_label.text = "%s is not implemented -- nothing to jump to" % func_name
		return

	_jump_to_registration(func_name)

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
