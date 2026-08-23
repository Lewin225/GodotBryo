extends Node

## Exercises script_viewer.gd's pure logic (span collection + BBCode
## construction) headlessly -- the tool's own UI/EditorInterface pieces
## only make sense inside the running editor (Engine.is_editor_hint() gates
## _ready() itself), so this bypasses that gate and calls the underlying
## functions directly, the same way other "private"-by-convention state in
## this project's debug tabs is reached into from outside (see
## world_streaming_debug_tab.gd).

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _ready() -> void:
	print("--- script_viewer.gd: span collection + BBCode ---")

	var viewer: Control = load("res://addons/script_viewer/script_viewer.gd").new()
	viewer._function_registry = ScriptFunctionRegistry.new()

	var source := "BEGIN OnActivate\nEnable\nSomeUnknownFunc\nEND\n"
	var program := ScriptParser.new(ScriptLexer.new(source).tokenize()).parse()

	var spans := []
	for block in program["blocks"]:
		viewer._collect_call_spans(block["stmts"], spans)
	spans.sort_custom(func(a, b): return a["start"] < b["start"])

	check(spans.size() == 2, "two calls found (got %d)" % spans.size())
	if spans.size() == 2:
		check(spans[0]["name"] == "Enable" and spans[0]["known"] == true, "Enable found and marked known")
		check(spans[1]["name"] == "SomeUnknownFunc" and spans[1]["known"] == false, "SomeUnknownFunc found and marked unknown")
		# The span must point at the REAL text -- not just the right name,
		# the right offsets into the original source string.
		check(source.substr(spans[0]["start"], spans[0]["end"] - spans[0]["start"]) == "Enable", "Enable span slices the real source text")
		check(source.substr(spans[1]["start"], spans[1]["end"] - spans[1]["start"]) == "SomeUnknownFunc", "SomeUnknownFunc span slices the real source text")

	var bbcode: String = viewer._build_bbcode(source, spans)
	check(bbcode.find("[color=%s]" % viewer.COLOR_KNOWN) != -1, "known span uses the known color")
	check(bbcode.find("[color=%s]" % viewer.COLOR_UNKNOWN) != -1, "unknown span uses the unknown color")
	check(bbcode.find("[url=known:Enable]Enable[/url]") != -1, "Enable wrapped as a 'known' url meta")
	check(bbcode.find("[url=unknown:SomeUnknownFunc]SomeUnknownFunc[/url]") != -1, "SomeUnknownFunc wrapped as an 'unknown' url meta")
	check(bbcode.find("BEGIN OnActivate") != -1, "non-call text (BEGIN OnActivate) preserved verbatim")

	print("--- bbcode escaping ---")
	var escaped: String = viewer._bbcode_escape("if [x] then")
	check(escaped == "if [lb]x] then", "literal '[' escaped to [lb]")

	print("--- registration line lookup ---")
	var line: int = viewer._find_registration_line("Enable")
	check(line != -1, "found a registration line for 'Enable' (got %d)" % line)
	var missing_line: int = viewer._find_registration_line("DefinitelyNotARealFunctionName")
	check(missing_line == -1, "unregistered function name returns -1")

	viewer.free()
	_finish()

func _finish() -> void:
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
