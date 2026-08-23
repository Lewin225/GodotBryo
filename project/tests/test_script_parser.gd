extends Node

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func parse(source: String) -> Dictionary:
	var tokens := ScriptLexer.new(source).tokenize()
	return ScriptParser.new(tokens).parse()

func _ready() -> void:
	print("--- ScriptParser ---")

	# Real source, hand-verified this session against the actual ESM record.
	var real_source := "scn VLCSafetyTrigger01SCRIPT\n\nRef ActivatorREF;\n\nBEGIN OnTriggerEnter\n\n\tSet ActivatorREF to GetActionRef;\n\tActivatorREF.MoveTo VHDLegateCampGateDestinationMarker;\n\nEND\n"
	var program := parse(real_source)
	check(program["script_name"] == "VLCSafetyTrigger01SCRIPT", "script_name parsed")
	check(program["declarations"].size() == 1, "one declaration parsed (got %d)" % program["declarations"].size())
	if program["declarations"].size() == 1:
		check(program["declarations"][0]["type"] == "ref", "declaration type is 'ref'")
		check(program["declarations"][0]["name"] == "ActivatorREF", "declaration name matches")
	check(program["blocks"].size() == 1, "one block parsed (got %d)" % program["blocks"].size())
	if program["blocks"].size() == 1:
		var block: Dictionary = program["blocks"][0]
		check(block["blocktype"] == "OnTriggerEnter", "blocktype matches")
		check(block["stmts"].size() == 2, "two statements in the block (got %d)" % block["stmts"].size())
		if block["stmts"].size() == 2:
			var set_stmt: Dictionary = block["stmts"][0]
			check(set_stmt["kind"] == "set", "first stmt is 'set'")
			check(set_stmt["target"] == "ActivatorREF", "set target matches")
			check(set_stmt["expr"]["kind"] == "call" and set_stmt["expr"]["name"] == "GetActionRef", "set expr is a GetActionRef call")

			var call_stmt: Dictionary = block["stmts"][1]
			check(call_stmt["kind"] == "call", "second stmt is a bare call")
			check(call_stmt["reference"] == "ActivatorREF", "call reference prefix matches")
			check(call_stmt["name"] == "MoveTo", "call name matches")
			check(call_stmt["args"].size() == 1, "MoveTo has one arg (got %d)" % call_stmt["args"].size())

	print("--- if/elseif/else ---")
	var if_source := "BEGIN OnActivate\nif (IsActionRef player)\n\tSet x to 1\nelseif (x == 2)\n\tSet x to 3\nelse\n\tSet x to 4\nendif\nEND\n"
	var if_program := parse(if_source)
	check(if_program["blocks"].size() == 1, "one block")
	var if_stmts: Array = if_program["blocks"][0]["stmts"]
	check(if_stmts.size() == 1, "one top-level statement (the if)")
	if if_stmts.size() == 1:
		var if_stmt: Dictionary = if_stmts[0]
		check(if_stmt["kind"] == "if", "stmt is 'if'")
		check(if_stmt["branches"].size() == 2, "two branches: if + elseif (got %d)" % if_stmt["branches"].size())
		check(if_stmt["else_stmts"].size() == 1, "one else statement (got %d)" % if_stmt["else_stmts"].size())

	print("--- expression precedence ---")
	var expr_source := "BEGIN GameMode\nif (1 + 2 * 3 == 7 && 1 || 0)\n\tSet x to 1\nendif\nEND\n"
	var expr_program := parse(expr_source)
	var cond: Dictionary = expr_program["blocks"][0]["stmts"][0]["branches"][0]["cond"]
	# top of the tree should be the lowest-precedence op: ||
	check(cond["kind"] == "binop" and cond["op"] == "||", "top-level op is '||' (lowest precedence)")

	print("--- two-word 'else if' (real, shipped data -- 182/2576 real scripts) ---")
	# Real, confirmed necessary: vMojaveExpressBoxSCRIPT's own real OnLoad
	# block writes "else if" as two words. Without this, the parser treated
	# it as an else-block whose body happened to start with an unrelated if
	# statement, swallowing every subsequent statement (including entire
	# other Begin/End blocks) up to whatever "endif" it stumbled on next --
	# confirmed directly this session via a real-play report (a ShowMessage
	# meant for OnActivate firing from OnLoad instead, because OnActivate's
	# whole body had been merged into OnLoad's).
	var else_if_source := "BEGIN OnLoad\nif (bFlag == 1)\n\tSet x to 1\nelse if (bFlag == 0)\n\tSet x to 2\nendif\nEND\nBEGIN OnActivate\n\tShowMessage SomeMsg\nEND\n"
	var else_if_program := parse(else_if_source)
	check(else_if_program["blocks"].size() == 2, "two real, separate blocks parsed (got %d)" % else_if_program["blocks"].size())
	if else_if_program["blocks"].size() == 2:
		check(String(else_if_program["blocks"][0]["blocktype"]) == "OnLoad", "first block is OnLoad")
		check(String(else_if_program["blocks"][1]["blocktype"]) == "OnActivate", "second block is a real, separate OnActivate -- not swallowed into OnLoad")
		var on_load_stmts: Array = else_if_program["blocks"][0]["stmts"]
		check(on_load_stmts.size() == 1, "OnLoad has exactly one statement: the if/else-if (got %d)" % on_load_stmts.size())
		if on_load_stmts.size() == 1:
			check(on_load_stmts[0]["branches"].size() == 2, "'else if' parsed as a second real branch, not a nested if inside an else block (got %d branches)" % on_load_stmts[0]["branches"].size())

	print("--- stray reserved keyword (real, shipped data) ---")
	# GSBrokenSMGScript's own real GameMode block: one "if", two "endif"s --
	# a real authoring mismatch that evidently still shipped. Confirmed this
	# session via the full script_engine_integration test: without this
	# fix, the stray endif parsed as a zero-arg call to a function literally
	# named "endif".
	var stray_source := "BEGIN GameMode\nif (x == 1)\n\tSet y to 1\nendif\nendif\nEND\n"
	var stray_program := parse(stray_source)
	var stray_stmts: Array = stray_program["blocks"][0]["stmts"]
	check(stray_stmts.size() == 2, "two top-level statements: the if, and the stray endif (got %d)" % stray_stmts.size())
	if stray_stmts.size() == 2:
		check(stray_stmts[0]["kind"] == "if", "first statement is the real if")
		check(stray_stmts[1]["kind"] == "noop", "stray endif parses as a noop, never a call named 'endif'")

	_finish()

func _finish() -> void:
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
