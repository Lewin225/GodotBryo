extends Node

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _ready() -> void:
	print("--- ScriptInterpreter: set/if/arithmetic ---")
	var registry := ScriptFunctionRegistry.new()
	var ctx := ScriptExecutionContext.new(null)

	var source := "int x\nint y\n\nBEGIN GameMode\nSet x to 1 + 2 * 3\nif (x == 7)\n\tSet y to 1\nelseif (x == 0)\n\tSet y to 2\nelse\n\tSet y to 3\nendif\nEND\n"
	var tokens := ScriptLexer.new(source).tokenize()
	var program := ScriptParser.new(tokens).parse()
	var interp := ScriptInterpreter.new(program, registry)

	check(interp.has_block("GameMode"), "has_block('GameMode') is true")
	check(not interp.has_block("OnActivate"), "has_block('OnActivate') is false (script has no such block)")

	interp.run_block("GameMode", ctx)
	check(ctx.get_local("x") == 7, "arithmetic + operator precedence: x == 7 (got %s)" % str(ctx.get_local("x")))
	check(ctx.get_local("y") == 1, "correct if-branch taken: y == 1 (got %s)" % str(ctx.get_local("y")))

	print("--- ScriptInterpreter: Enable/Disable/GetDisabled on the calling node ---")
	var node := Node3D.new()
	add_child(node)
	var node_ctx := ScriptExecutionContext.new(node)
	var toggle_source := "BEGIN OnActivate\nDisable\nEND\n"
	var toggle_program := ScriptParser.new(ScriptLexer.new(toggle_source).tokenize()).parse()
	var toggle_interp := ScriptInterpreter.new(toggle_program, registry)
	toggle_interp.run_block("OnActivate", node_ctx)
	check(node.visible == false, "Disable set the calling node's visible to false")
	node.queue_free()

	print("--- ScriptInterpreter: unimplemented function returns 0, doesn't crash ---")
	var unknown_source := "BEGIN GameMode\nSet z to SomeFunctionThatDoesNotExist\nEND\n"
	var unknown_program := ScriptParser.new(ScriptLexer.new(unknown_source).tokenize()).parse()
	var unknown_interp := ScriptInterpreter.new(unknown_program, registry)
	unknown_interp.run_block("GameMode", ctx)
	check(ctx.get_local("z") == 0, "unimplemented function call evaluates to 0, no crash")

	print("--- ScriptEngine: end-to-end via a real script from the ESM ---")
	_test_script_engine()

	_finish()

func _test_script_engine() -> void:
	var esm := EsmReader.new()
	var opened := esm.open("/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/FalloutNV.esm")
	check(opened, "EsmReader opened FalloutNV.esm")
	if not opened:
		return

	var engine := ScriptEngine.new()
	add_child(engine)
	engine.esm = esm

	var node := Node3D.new()
	add_child(node)
	# VLCSafetyTrigger01SCRIPT's own real form_id, hand-verified this
	# session (test_script_esm.gd asserts the same value).
	engine.register_scripted_node(node, 0x17b787)
	check(engine.is_scripted(node), "node registered with ScriptEngine")

	var actor := Node3D.new()
	add_child(actor)
	engine.dispatch_event(node, "OnTriggerEnter", actor)
	# The real script's own body: `Set ActivatorREF to GetActionRef;` then
	# `ActivatorREF.MoveTo ...` (MoveTo is unimplemented -- logs and no-ops,
	# doesn't crash the dispatch).
	check(engine.function_registry != null, "ScriptEngine owns a real function registry")

	engine.unregister_scripted_node(node)
	check(not engine.is_scripted(node), "unregister_scripted_node() removes it")

	node.queue_free()
	actor.queue_free()
	engine.queue_free()

func _finish() -> void:
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
