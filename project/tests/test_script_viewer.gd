extends Node

## Exercises script_viewer.gd's pure logic (call-name collection +
## registration lookup) headlessly -- the tool's own UI/EditorInterface/
## CodeEdit symbol-lookup pieces only make sense inside the running editor
## (Engine.is_editor_hint() gates _ready() itself), so this bypasses that
## gate and calls the underlying functions directly, the same way other
## "private"-by-convention state in this project's debug tabs is reached
## into from outside (see world_streaming_debug_tab.gd).

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _ready() -> void:
	print("--- script_viewer.gd: call-name collection ---")

	var viewer: Control = load("res://addons/script_viewer/script_viewer.gd").new()
	viewer._function_registry = ScriptFunctionRegistry.new()

	# Same call site twice with different real-world casing (the language is
	# case-insensitive; a script can legitimately do this) -- both variants
	# must be collected separately for the highlighter, but resolve to the
	# same known/unknown answer either way.
	var source := "BEGIN OnActivate\nEnable\nenable\nSomeUnknownFunc\nEND\n"
	var program := ScriptParser.new(ScriptLexer.new(source).tokenize()).parse()

	var casing_variants := {}
	for block in program["blocks"]:
		viewer._collect_call_names(block["stmts"], casing_variants)

	check(casing_variants.size() == 3, "three distinct casing variants found (got %d)" % casing_variants.size())
	check(casing_variants.get("Enable") == true, "'Enable' (capitalized) marked known")
	check(casing_variants.get("enable") == true, "'enable' (lowercase) also marked known")
	check(casing_variants.get("SomeUnknownFunc") == false, "'SomeUnknownFunc' marked unknown")

	print("--- symbol validate/lookup (case-insensitive) ---")
	viewer._found_calls_lower.clear()
	for variant in casing_variants:
		viewer._found_calls_lower[String(variant).to_lower()] = casing_variants[variant]

	check(viewer._found_calls_lower.has("enable"), "lowercase lookup finds 'enable' regardless of source casing")
	check(viewer._found_calls_lower["enable"] == true, "'enable' resolves known via case-insensitive lookup")
	check(viewer._found_calls_lower.has("someunknownfunc"), "lowercase lookup finds the unknown call too")
	check(not viewer._found_calls_lower.has("notarealcallhere"), "a name never seen in this script isn't present")

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
