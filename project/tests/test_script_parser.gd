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

	_finish()

func _finish() -> void:
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
