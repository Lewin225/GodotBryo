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

	print("--- ScriptInterpreter: unimplemented function (statement position) returns 0, doesn't crash ---")
	# A bare call STATEMENT -- always a real call (_parse_call_statement()),
	# unaffected by the "name" node primary-position case tested below.
	var unknown_source := "BEGIN GameMode\nSomeFunctionThatDoesNotExist\nEND\n"
	var unknown_program := ScriptParser.new(ScriptLexer.new(unknown_source).tokenize()).parse()
	var unknown_interp := ScriptInterpreter.new(unknown_program, registry)
	unknown_interp.run_block("GameMode", ctx) # would push a SCRIPT ERROR / crash the test run if this misparsed as anything but a real call
	check(true, "unimplemented function call statement evaluates safely, no crash")

	print("--- ScriptInterpreter: unresolved name in expression position evaluates to its own literal text ---")
	# Real, confirmed necessary for ShowMessage's own MESG editor-ID lookup
	# (script_parser.gd's own doc comment on _parse_ident_primary()) -- an
	# undeclared, unprefixed identifier reached as an if/set operand or a
	# call argument is a reference/editor-ID name, not a phantom call.
	var name_ctx := ScriptExecutionContext.new(null)
	var name_source := "BEGIN GameMode\nSet z to SomeReferenceEditorID\nEND\n"
	var name_program := ScriptParser.new(ScriptLexer.new(name_source).tokenize()).parse()
	ScriptInterpreter.new(name_program, registry).run_block("GameMode", name_ctx)
	check(name_ctx.get_local("z") == "SomeReferenceEditorID", "unresolved name evaluates to its own literal text (got %s)" % str(name_ctx.get_local("z")))

	print("--- ScriptInterpreter: comparing a name-literal against a number never crashes ---")
	# Real Gamebryo never actually compares a ref against a number with == --
	# the real compiler would reject the type mismatch outright. This
	# interpreter can transiently hit it anyway (a "name" standing in for an
	# unresolved ref), and must degrade to false rather than crash the way
	# GDScript's own == does for genuinely incompatible Variant types.
	var cmp_ctx := ScriptExecutionContext.new(null)
	var cmp_source := "BEGIN GameMode\nif (SomeReferenceEditorID == 1)\n\tSet z to 1\nelse\n\tSet z to 2\nendif\nEND\n"
	var cmp_program := ScriptParser.new(ScriptLexer.new(cmp_source).tokenize()).parse()
	ScriptInterpreter.new(cmp_program, registry).run_block("GameMode", cmp_ctx)
	check(cmp_ctx.get_local("z") == 2, "String-vs-int == never crashes, resolves to the else branch (got %s)" % str(cmp_ctx.get_local("z")))

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

	print("--- ScriptFunctionRegistry: esm propagation for ShowMessage ---")
	# ScriptEngine.esm's own setter propagates to function_registry.esm too
	# (script_engine.gd's own doc comment) -- confirmed here rather than
	# assumed, since that propagation is the only thing letting ShowMessage
	# resolve anything at all. Deliberately NOT calling ShowMessage itself
	# here (or anywhere in the automated suite) -- it triggers a real
	# OS.alert(), and confirmed directly this session: when a real display
	# is available (an active editor/Play session, e.g.), that genuinely
	# blocks waiting for a click, exactly as documented -- correct behavior
	# for the feature, but it makes an automated test hang non-deterministically
	# depending on the environment. get_message_by_editor_id()'s own
	# resolution is covered headlessly in test_script_esm.gd instead, which
	# is the actual risk surface (real ESM parsing); OS.alert() itself is a
	# one-line stdlib call with nothing of ours left to verify.
	check(engine.function_registry.esm == esm, "function_registry.esm was propagated by the esm setter")

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
