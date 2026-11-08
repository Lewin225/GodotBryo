class_name ConsoleSession
extends RefCounted

## The console's state and command runner, without UI (ConsoleOverlay shows
## it). A line splits into statements at `|` (split_statements); each is a
## console command (ConsoleCompleter.META_COMMANDS) or a script statement run
## through ScriptServer.run_debug_line, as the target reference when one is
## set (`prid`) and the statement names none.
##
## Before running, a script statement is checked against the ESM: an unknown
## function is an error, and an argument that should name a record but names
## none, or a record of the wrong type, gets a warning (it still runs, so the
## engine's own reply shows). `0x` FormIDs are accepted where script source
## would need an EditorID: as an argument they become the record's EditorID,
## and as a `0x0010ABCD.` prefix the statement runs on that reference. A
## FormID is `0x` and hex, or the 8 hex digits the GECK shows (`00004322`);
## a name that is an EditorID is that EditorID first.

## The reference statements without a `Ref.` prefix act on changed.
signal target_changed(reference: EsmReference)
## Output to show: {kind, text}; kind is input, result, info, warning or
## error. `clear` asks the view to clear its output.
signal output(entry: Dictionary)
signal clear_requested

## The console's buttons, in order. `label` is a String, or two (while the
## target is not disabled, while it is). `command` likewise, with `state`
## "disabled" choosing. `type_only` puts the command in the input instead of
## running it, with its last word selected to type over. `ignore_target` runs
## it as the player (no calling reference); `needs_target` greys the button
## out without a target. A button is also greyed out when its function is not
## registered.
const BUTTONS := [
	{"label": ["Disable", "Enable"], "command": ["Disable", "Enable"], "state": "disabled", "needs_target": true,
			"tip": "Disable the target, or enable it when it is disabled"},
	{"label": "TCL", "command": "TCL", "ignore_target": true, "tip": "Toggle collision (noclip) on the player"},
	{"label": "TGM", "command": "TGM", "ignore_target": true, "tip": "Toggle god mode (a flag only, until there is a damage system)"},
	{"label": "TDM", "command": "TDM", "ignore_target": true, "tip": "Toggle demigod mode (a flag only, until there is a damage system)"},
	{"label": "+ Caps", "command": "player.AddItem Caps001 1000", "type_only": true, "tip": "Types player.AddItem Caps001 1000 with the amount selected; Enter runs it"},
	{"label": "Enable controls", "command": "EnablePlayerControls", "ignore_target": true, "tip": "Enable every player control (EnablePlayerControls with no arguments), for when a script left them disabled"},
	{"label": "Race menu", "command": "ShowRaceMenu", "ignore_target": true, "tip": "Open the race menu"},
	{"label": "Kill", "command": "Kill", "needs_target": true, "tip": "Take the target's Health to 0"},
	{"label": "Resurrect", "command": "Resurrect", "needs_target": true, "tip": "Restore the target's Health"},
]

## Most commands kept in history.
const HISTORY_LIMIT := 500
## Deepest `bat` nesting, so a file that runs itself stops.
const MAX_BATCH_DEPTH := 4

var script_server: Node
var completer: ConsoleCompleter
## The reference statements without a `Ref.` prefix act on; null for none.
var target: EsmReference = null
var history: Array[String] = []
var _batch_depth := 0

func _init(server: Node = null) -> void:
	script_server = server
	completer = ConsoleCompleter.new(server.function_registry if server != null else null)

## Record types the status line counts.
const STATUS_RECORD_TYPES := ["NPC_", "CREA", "WEAP", "ARMO", "ALCH", "MISC", "CELL", "QUST"]

## Prints what the console works with: the loaded plugins, record counts, the
## script functions and where the player is. Needs the EditorID index.
func report_status() -> void:
	var esm_server := EsmReference.get_esm_server()
	if esm_server == null or not completer.ensure_index():
		_emit("warning", "The ESM is not loaded yet")
		return
	_emit("info", "Plugins: %s" % ", ".join(esm_server.load_order))
	var counts := PackedStringArray()
	for record_type: String in STATUS_RECORD_TYPES:
		counts.append("%s %d" % [record_type, completer.record_count(record_type)])
	_emit("info", "Records: %s  (%d records, %d with an EditorID)" % [" · ".join(counts), completer.total_record_count(), completer.index_size()])
	var without_arguments := 0
	for name in completer.function_names():
		without_arguments += int(completer.signature(name) == null)
	_emit("info", "Functions: %d script functions registered, %s" % [completer.function_names().size(),
			"all complete their arguments" if without_arguments == 0 else "%d do not complete their arguments" % without_arguments])
	_emit("info", "Space: " + describe_space())

## Where the player is: an interior CELL by EditorID, or a worldspace with
## the grid coordinate; "not placed yet" before the player has a position.
func describe_space() -> String:
	var player: EsmReference = script_server.player_reference if script_server != null else null
	if player == null or player.current_space_form_id == 0:
		return "the player is not placed yet"
	var space := completer.record_for_form_id(player.current_space_form_id)
	var name := String(space.get("editor_id", "%08X" % player.current_space_form_id))
	if space.get("record_type", "") == "WRLD":
		var grid := EsmServer.exterior_grid_coord(player.position)
		return "%s, grid (%d, %d)" % [name, grid.x, grid.y]
	return "%s (interior)" % name

## Runs a line of one or more `|`-separated statements, recording it in
## history. Output arrives through `output`. Without `use_target` the
## statements run with no calling reference, as the player.
func submit(line: String, use_target := true) -> void:
	var text := line.strip_edges()
	if text.is_empty():
		return
	if history.is_empty() or history.back() != text:
		history.append(text)
		if history.size() > HISTORY_LIMIT:
			history.pop_front()
	_emit("input", text)
	for statement in split_statements(text):
		run_statement(statement, use_target)

## A button's label, for the target's current state.
func button_label(button: Dictionary) -> String:
	var label: Variant = button["label"]
	return String(label[_button_state(button)]) if label is Array else String(label)

## A button's command, for the target's current state.
func button_command(button: Dictionary) -> String:
	var command: Variant = button["command"]
	return String(command[_button_state(button)]) if command is Array else String(command)

func _button_state(button: Dictionary) -> int:
	return 1 if button.get("state") == "disabled" and target != null and target.is_disabled() else 0

## Whether a button can run now, else why not as {enabled: false, reason}.
func button_status(button: Dictionary) -> Dictionary:
	var function_name := button_command(button).get_slice(" ", 0)
	function_name = function_name.substr(function_name.rfind(".") + 1)
	if not completer.is_function(function_name):
		return {"enabled": false, "reason": "%s is not a registered script function yet" % function_name}
	if button.get("needs_target", false) and target == null:
		return {"enabled": false, "reason": "needs a target: click one in the world, or prid"}
	return {"enabled": true, "reason": ""}

## Sets the target reference (prid).
func set_target(reference: EsmReference) -> void:
	if reference == target:
		return
	target = reference
	target_changed.emit(reference)

## A reference's short label: its EditorID, else its instance_id, with its
## base's EditorID.
func describe_reference(reference: EsmReference) -> String:
	if reference == null:
		return "none"
	if script_server != null and reference == script_server.player_reference:
		return "player"
	var label := String(reference.instance_id)
	var esm_server := EsmReference.get_esm_server()
	if esm_server != null and esm_server.is_ready() and completer.ensure_index():
		var record := completer.record_for_form_id(esm_server.form_id_for_instance_id(label))
		if not record.is_empty():
			label = String(record["editor_id"])
	if reference.base != null:
		if not reference.base.editor_id.is_empty():
			label += " (%s)" % reference.base.editor_id
		if not reference.base.record_type.is_empty():
			label += " [%s]" % reference.base.record_type
	return label

## Runs one statement: a console command, or a script statement.
func run_statement(statement: String, use_target := true) -> void:
	var words := ConsoleCompleter._tokens(statement)
	if words.is_empty():
		return
	var head := String(words[0]["text"])
	var args := PackedStringArray()
	for i in range(1, words.size()):
		args.append(String(words[i]["text"]))
	match head.to_lower():
		"help": _help(args)
		"find": _find(args)
		"info": _info(args)
		"prid": _prid(args)
		"bat": _bat(args)
		"history": _history(args)
		"status": report_status()
		"clear", "cls": clear_requested.emit()
		_: _run_script(statement, words, use_target)

# --- Script statements --------------------------------------------------------

func _run_script(statement: String, words: Array, use_target := true) -> void:
	if script_server == null:
		_emit("error", "ScriptServer not found")
		return
	var head := String(words[0]["text"])
	var run_as := target if use_target else null
	var dot := head.rfind(".")
	var function_name := head.substr(dot + 1) if dot >= 0 else head
	# `0x0010ABCD.Func ...`: a reference by FormID, which script source has no
	# way to name, becomes the statement's calling reference.
	if dot >= 0:
		var form_id := ConsoleCompleter.parse_form_id(head.left(dot))
		if form_id >= 0:
			run_as = _reference_for_form_id(form_id)
			if run_as == null:
				_emit("error", "0x%08X is not a placed reference" % form_id)
				return
			statement = statement.substr(int(words[0]["start"]) + dot + 1)
			words = ConsoleCompleter._tokens(statement)
	if head.to_lower() != "set" and not completer.is_function(function_name):
		var close := _close_functions(function_name)
		_emit("error", "'%s' is not a script function%s" % [function_name,
				"; did you mean %s?" % ", ".join(close) if not close.is_empty() else ""])
		return
	statement = _check_arguments(statement, words, function_name)
	var reply: Dictionary = script_server.run_debug_line(statement, run_as)
	if not bool(reply.get("ok", false)):
		_emit("error", String(reply.get("message", "failed")))
		return
	var label := completer.canonical_name(function_name) if head.to_lower() != "set" else "set"
	_emit("result", "%s >> %s" % [label, format_value(reply.get("result"))])

## Warns about arguments that should name a record but do not, and replaces
## `0x` FormID arguments with their record's EditorID. Returns the statement
## to run.
func _check_arguments(statement: String, words: Array, function_name: String) -> String:
	var params: Variant = completer.signature(function_name)
	if params == null or not completer.ensure_index():
		return statement
	var rewritten := statement
	# Replace from the end, so earlier spans stay valid.
	for i in range(mini(words.size() - 1, (params as Array).size()) - 1, -1, -1):
		var word: Dictionary = words[i + 1]
		var token := String(word["text"])
		var param: Dictionary = params[i]
		var kind := String(param["kind"])
		if not ConsoleCompleter.is_record_kind(kind) or token.begins_with("\""):
			continue
		var form_id := ConsoleCompleter.parse_form_id(token)
		if form_id < 0 and token.is_valid_float():
			continue
		var record := _record_named(token, form_id)
		if form_id >= 0 and not record.is_empty() and String(record["editor_id"]) != token:
			rewritten = rewritten.left(int(word["start"])) + String(record["editor_id"]) + rewritten.substr(int(word["end"]))
			_emit("info", "%s = %s" % [token, String(record["editor_id"])])
		if record.is_empty():
			if (kind == "ref" or kind == "actor") and (token.to_lower() == "player" or _is_reference_local(token)):
				continue
			if form_id >= 0:
				_emit("warning", "%s: %s has no EditorID, which script arguments need" % [param["name"], token])
				continue
			var close := completer.closest(token, kind)
			_emit("warning", "%s: no %s has the EditorID '%s'%s" % [param["name"], _kind_label(kind), token,
					"; did you mean %s?" % ", ".join(close) if not close.is_empty() else ""])
		elif not ConsoleCompleter.kind_accepts(kind, String(record["record_type"])):
			_emit("warning", "%s: '%s' is a %s, not a %s" % [param["name"], token, record["record_type"], _kind_label(kind)])
	return rewritten

## The record a token names: its EditorID, else its FormID (`form_id`, from
## ConsoleCompleter.parse_form_id), which is {} for a record with no EditorID.
func _record_named(token: String, form_id: int) -> Dictionary:
	var record := completer.resolve(token) if not token.to_lower().begins_with("0x") else {}
	if record.is_empty() and form_id >= 0:
		record = completer.record_for_form_id(form_id)
	return record

func _is_reference_local(token: String) -> bool:
	if target == null or target.script_instance == null:
		return false
	return target.script_instance.locals.get(token) is EsmReference

static func _kind_label(kind: String) -> String:
	var types: Array = ConsoleCompleter.KIND_RECORD_TYPES.get(kind, [])
	if kind == "interior_cell":
		return "interior CELL"
	return "/".join(types) if types.size() <= 4 else kind

func _close_functions(name: String) -> PackedStringArray:
	var scored: Array = []
	for candidate in completer.function_names():
		var score := name.to_lower().similarity(candidate.to_lower())
		if score > 0.5:
			scored.append([score, candidate])
	scored.sort_custom(func(a, b): return a[0] > b[0])
	var out := PackedStringArray()
	for entry in scored.slice(0, 3):
		out.append(entry[1])
	return out

## A script value as the console shows it: references by label, records by
## EditorID, whole floats without a fraction.
func format_value(value: Variant) -> String:
	if value == null:
		return "(nothing)"
	if value is EsmReference:
		return describe_reference(value)
	if value is EsmBase:
		return "%s %08X" % [(value as EsmBase).editor_id, (value as EsmBase).form_id]
	if value is float:
		return str(int(value)) if is_equal_approx(value, roundf(value)) and absf(value) < 1e15 else "%.4f" % value
	return str(value)

func _reference_for_form_id(form_id: int) -> EsmReference:
	var esm_server := EsmReference.get_esm_server()
	if esm_server == null or not esm_server.is_ready():
		return null
	if form_id == 0x14 and script_server != null:
		return script_server.player_reference
	return esm_server.get_reference_by_form_id(form_id)

## A reference by `player`, EditorID or `0x` FormID; null when none.
func find_reference(name: String) -> EsmReference:
	if name.to_lower() == "player":
		return script_server.player_reference if script_server != null else null
	var esm_server := EsmReference.get_esm_server()
	if esm_server != null and esm_server.is_ready():
		var named: EsmReference = esm_server.find_reference_by_editor_id(name)
		if named != null:
			return named
	var form_id := ConsoleCompleter.parse_form_id(name)
	return _reference_for_form_id(form_id) if form_id >= 0 else null

# --- Console commands ---------------------------------------------------------

func _help(args: PackedStringArray) -> void:
	if args.is_empty():
		_emit("info", "Console commands:")
		for names: String in ConsoleCompleter.META_COMMANDS:
			var meta: Array = ConsoleCompleter.META_COMMANDS[names]
			_emit("info", "  %-28s %s" % [completer.usage(names.split("|")[0]), meta[1]])
		_emit("info", "Script: [Ref.]Function args..., or set Variable to Value. Separate statements with |.")
		_emit("info", "%d script functions are registered; `help <text>` lists those matching." % completer.function_names().size())
		_emit("info", "Tab completes, Up/Down browse suggestions or history, a click in the world picks the target.")
		return
	var query := args[0]
	if completer.is_function(query):
		var name := completer.canonical_name(query)
		_emit("info", completer.usage(name))
		var params: Variant = completer.signature(name)
		if params == null:
			_emit("info", "  (arguments not recorded in ConsoleCompleter.SIGNATURES)")
		else:
			for p: Dictionary in params:
				_emit("info", "  %-20s %s%s" % [p["name"], p["kind"], " (optional)" if p["optional"] else ""])
		var aliases := completer.aliases(name)
		if not aliases.is_empty():
			_emit("info", "  shares its arguments with: " + ", ".join(aliases))
		return
	if ConsoleCompleter.meta_command(query) != null:
		var meta: Array = ConsoleCompleter.meta_command(query)
		_emit("info", "%s  -  %s" % [completer.usage(query.to_lower()), meta[1]])
		return
	var matches := PackedStringArray()
	for name in completer.function_names():
		if name.to_lower().contains(query.to_lower()):
			matches.append(completer.usage(name))
	if matches.is_empty():
		_emit("warning", "No function or command matches '%s'" % query)
	for line in matches:
		_emit("info", "  " + line)

func _find(args: PackedStringArray) -> void:
	if args.is_empty():
		_emit("error", "find Text [RecordType]")
		return
	if not completer.ensure_index():
		_emit("error", "The ESM is not loaded yet")
		return
	var text := args[0].trim_prefix("\"").trim_suffix("\"")
	var records := completer.find(text, args[1] if args.size() > 1 else "", 51)
	if records.is_empty():
		_emit("warning", "No EditorID or name contains '%s'" % text)
	for record in records.slice(0, 50):
		_emit("info", "  %-36s %s %08X %s" % [record["editor_id"], record["record_type"], record["form_id"],
				"\"%s\"" % record["full_name"] if not String(record["full_name"]).is_empty() else ""])
	if records.size() > 50:
		_emit("info", "  ... more; narrow the text or give a record type")

func _info(args: PackedStringArray) -> void:
	if args.is_empty():
		if target == null:
			_emit("error", "info Name, or set a target with prid")
		else:
			_info_reference(target)
		return
	var name := args[0]
	var reference := find_reference(name)
	if reference != null:
		_info_reference(reference)
		return
	if not completer.ensure_index():
		_emit("error", "The ESM is not loaded yet")
		return
	var form_id := ConsoleCompleter.parse_form_id(name)
	var record := _record_named(name, form_id)
	if record.is_empty():
		var close := completer.closest(name, "any")
		_emit("error", "No record has the EditorID '%s'%s" % [name, "; did you mean %s?" % ", ".join(close) if not close.is_empty() else ""])
		return
	_info_record(record)

func _info_record(record: Dictionary) -> void:
	_emit("info", "%s  %s %08X%s" % [record["editor_id"], record["record_type"], record["form_id"],
			"  \"%s\"" % record["full_name"] if not String(record["full_name"]).is_empty() else ""])
	var esm_server := EsmReference.get_esm_server()
	var base: EsmBase = esm_server.get_base(int(record["form_id"])) if esm_server != null else null
	if base != null:
		var script: Script = base.get_script()
		_emit("info", "  resource: %s" % (script.get_global_name() if script != null and script.get_global_name() != "" else "EsmBase"))
		var script_form_id := base.script_form_id
		if script_form_id != 0:
			var script_record := completer.record_for_form_id(script_form_id)
			_emit("info", "  script: %s %08X" % [script_record.get("editor_id", "?"), script_form_id])

func _info_reference(reference: EsmReference) -> void:
	_emit("info", "%s  [%s]" % [describe_reference(reference), reference.instance_id])
	if reference.base != null:
		_emit("info", "  base: %s %s %08X%s" % [reference.base.editor_id, reference.base.record_type, reference.base.form_id,
				"  \"%s\"" % reference.base.full_name if reference.base.full_name != "" else ""])
	var space := completer.record_for_form_id(reference.current_space_form_id) if completer.ensure_index() else {}
	_emit("info", "  space: %s %08X   position (Gamebryo units): %.0f %.0f %.0f" % [
			space.get("editor_id", "(none)"), reference.current_space_form_id,
			reference.position.x * 70.0, reference.position.y * 70.0, reference.position.z * 70.0])
	_emit("info", "  disabled: %s   physicalised: %s" % ["yes" if reference.is_disabled() else "no",
			"yes" if EsmNode.node_for(reference) != null else "no"])
	if reference.script_instance != null:
		var script_record := completer.record_for_form_id(reference.script_instance.script_form_id)
		_emit("info", "  script: %s, %d variable(s)" % [script_record.get("editor_id", "?"), reference.script_instance.locals.size()])
		for variable in reference.script_instance.locals:
			_emit("info", "    %-24s %s" % [variable, format_value(reference.script_instance.locals[variable])])

func _prid(args: PackedStringArray) -> void:
	if args.is_empty():
		_emit("info", "target: " + describe_reference(target))
		return
	if args[0].to_lower() == "none":
		set_target(null)
		_emit("info", "target cleared")
		return
	var reference := find_reference(args[0])
	if reference == null:
		var close := completer.closest(args[0], "ref") if completer.ensure_index() else PackedStringArray()
		_emit("error", "'%s' is not a placed reference%s" % [args[0], "; did you mean %s?" % ", ".join(close) if not close.is_empty() else ""])
		return
	set_target(reference)
	_emit("info", "target: " + describe_reference(reference))

func _history(args: PackedStringArray) -> void:
	var count := int(args[0]) if not args.is_empty() and args[0].is_valid_int() else 20
	var first := maxi(history.size() - 1 - count, 0)
	# The last entry is this `history` command itself.
	for i in range(first, history.size() - 1):
		_emit("info", "  %3d  %s" % [i + 1, history[i]])

func _bat(args: PackedStringArray) -> void:
	if args.is_empty():
		_emit("error", "bat File")
		return
	if _batch_depth >= MAX_BATCH_DEPTH:
		_emit("error", "bat: nested %d deep, stopping" % MAX_BATCH_DEPTH)
		return
	var path := batch_path(args[0].trim_prefix("\"").trim_suffix("\""))
	if path.is_empty():
		_emit("error", "bat: no file '%s' (looked in user://console/, user:// and as a path)" % args[0])
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_emit("error", "bat: cannot read %s" % path)
		return
	_emit("info", "bat " + path)
	_batch_depth += 1
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty() or line.begins_with(";"):
			continue
		_emit("input", line)
		for statement in split_statements(line):
			run_statement(statement)
	_batch_depth -= 1

## Where `bat name` reads from: user://console/name, user://name, or name as
## a path, each also with `.txt`; "" when none exists.
static func batch_path(name: String) -> String:
	for candidate in ["user://console/" + name, "user://" + name, name]:
		for path in [candidate, candidate + ".txt"]:
			if FileAccess.file_exists(path):
				return path
	return ""

func _emit(kind: String, text: String) -> void:
	output.emit({"kind": kind, "text": text})

## Splits a console line into statements at each `|`, so several commands run
## from one line. A `||` (logical or) and a `|` inside quotes do not split.
static func split_statements(line: String) -> PackedStringArray:
	var statements := PackedStringArray()
	var current := ""
	var in_quotes := false
	var index := 0
	while index < line.length():
		var character := line[index]
		if character == "\"":
			in_quotes = not in_quotes
		var is_or := index + 1 < line.length() and line[index + 1] == "|"
		if character == "|" and not in_quotes and is_or:
			current += "||"
			index += 2
			continue
		if character == "|" and not in_quotes:
			_add_statement(statements, current)
			current = ""
		else:
			current += character
		index += 1
	_add_statement(statements, current)
	return statements

static func _add_statement(statements: PackedStringArray, text: String) -> void:
	var statement := text.strip_edges()
	if not statement.is_empty():
		statements.append(statement)
