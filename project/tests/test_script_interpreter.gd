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

	print("--- ScriptInterpreter: Disable acts on the calling reference's node ---")
	var toggled_reference := EsmReference.new()
	var node := EsmNode.new()
	node.reference = toggled_reference
	add_child(node)
	check(EsmNode.node_for(toggled_reference) == node, "EsmNode.node_for finds the node representing a reference")
	var node_ctx := ScriptExecutionContext.new(toggled_reference)
	var toggle_source := "BEGIN OnActivate\nDisable\nEND\n"
	var toggle_program := ScriptParser.new(ScriptLexer.new(toggle_source).tokenize()).parse()
	var toggle_interp := ScriptInterpreter.new(toggle_program, registry)
	toggle_interp.run_block("OnActivate", node_ctx)
	check(node.visible == false, "Disable hid the calling reference's node")
	remove_child(node)
	check(EsmNode.node_for(toggled_reference) == null, "a node leaving the tree is no longer found for its reference")
	node.free()

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

	print("--- ScriptExecutionContext.is_truthy(): never crashes on a name-literal (real, reported crash) ---")
	# Real crash reported directly against play (a "SPECIAL machine" script):
	# `is_truthy: Invalid call. Nonexistent 'bool' constructor.` -- an
	# unresolved "name" node's own String value reached a bare `if
	# (SomeUnresolvedRef)` truthiness check, and GDScript's own bool()
	# constructor turned out to be just as strict as String() and == already
	# were, throwing instead of converting.
	check(ScriptExecutionContext.is_truthy("SomeUnresolvedRef") == true, "a non-empty String is truthy")
	check(ScriptExecutionContext.is_truthy("") == false, "an empty String is falsy")
	check(ScriptExecutionContext.is_truthy(0) == false, "int 0 is falsy")
	check(ScriptExecutionContext.is_truthy(1) == true, "a non-zero int is truthy")
	check(ScriptExecutionContext.is_truthy(0.0) == false, "float 0.0 is falsy")
	var truthy_source := "BEGIN GameMode\nif (SomeUnresolvedRef)\n\tSet z to 1\nelse\n\tSet z to 2\nendif\nEND\n"
	var truthy_program := ScriptParser.new(ScriptLexer.new(truthy_source).tokenize()).parse()
	var truthy_ctx := ScriptExecutionContext.new(null)
	ScriptInterpreter.new(truthy_program, registry).run_block("GameMode", truthy_ctx)
	check(truthy_ctx.get_local("z") == 1, "a bare unresolved-ref condition evaluates truthy end-to-end, no crash (got %s)" % str(truthy_ctx.get_local("z")))

	print("--- ScriptInterpreter/IsActionRef: 'player' resolves to the player's reference ---")
	var player_ref := ActorReference.new()
	var player_ctx := ScriptExecutionContext.new(null)
	player_ctx.action_ref = player_ref
	player_ctx.player_reference = player_ref
	var player_source := "BEGIN OnActivate\nif (IsActionRef player)\n\tSet z to 1\nelse\n\tSet z to 2\nendif\nEND\n"
	var player_program := ScriptParser.new(ScriptLexer.new(player_source).tokenize()).parse()
	ScriptInterpreter.new(player_program, registry).run_block("OnActivate", player_ctx)
	check(player_ctx.get_local("z") == 1, "IsActionRef player is true when the action reference is the player's (got %s)" % str(player_ctx.get_local("z")))

	var other_ctx := ScriptExecutionContext.new(null)
	other_ctx.action_ref = ActorReference.new()
	other_ctx.player_reference = player_ref
	ScriptInterpreter.new(player_program, registry).run_block("OnActivate", other_ctx)
	check(other_ctx.get_local("z") == 2, "IsActionRef player is false for another actor (got %s)" % str(other_ctx.get_local("z")))

	print("--- ScriptInterpreter: block parameters gate on the dispatch subject ---")
	var gated_source := "BEGIN OnActivate Player\nSet z to 1\nEND\n"
	var gated := ScriptInterpreter.new(ScriptParser.new(ScriptLexer.new(gated_source).tokenize()).parse(), registry)
	var gate_ctx := ScriptExecutionContext.new(null)
	gate_ctx.player_reference = player_ref
	gated.run_block("OnActivate", gate_ctx, other_ctx.action_ref)
	check(gate_ctx.get_local("z") == null, "OnActivate Player does not run for another activator")
	check(not gated.has_block_for("OnActivate", gate_ctx, other_ctx.action_ref), "has_block_for is false for another activator")
	gated.run_block("OnActivate", gate_ctx, player_ref)
	check(gate_ctx.get_local("z") == 1, "OnActivate Player runs for the player")
	var ungated := ScriptInterpreter.new(player_program, registry)
	check(ungated.has_block_for("OnActivate", gate_ctx, other_ctx.action_ref), "a block without a parameter runs for any activator")

	print("--- ScriptServer: real scripts from the ESM ---")
	await _test_script_server()

	_finish()

func _test_script_server() -> void:
	var esm_server = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var server = get_node("/root/ScriptServer")
	check(server.function_registry.esm == esm_server.reader, "ScriptServer reads scripts through EsmServer's reader")

	# A real actor to act as activator and player.
	var interior := int(esm_server.reader.find_cell_by_editor_id("GSDocMitchellHouse").get("form_id", 0))
	var actors: Array[ActorReference] = []
	for reference in esm_server.get_references_in_cell(interior):
		if reference is ActorReference:
			actors.append(reference)
	check(not actors.is_empty(), "GSDocMitchellHouse has a placed actor")
	if actors.is_empty():
		return
	var actor: ActorReference = actors[0]

	# VLCSafetyTrigger01SCRIPT: `Set ActivatorREF to GetActionRef` on OnTriggerEnter.
	var trigger_base := ActivatorBase.new()
	trigger_base.script_form_id = 0x17b787
	var trigger := ActivatorReference.new()
	trigger.base = trigger_base
	trigger.instance_id = "test:trigger"
	var instance: ScriptInstance = server.get_script_instance(trigger)
	check(instance != null and trigger.script_instance == instance, "a reference's ScriptInstance is created on first use and stored on it")
	check(instance != null and instance.has_local("ActivatorREF"), "declared locals are seeded")
	server.dispatch_event(trigger, "OnTriggerEnter", actor)
	check(trigger.script_instance.locals.get("activatorref") == {"ref": actor.instance_id}, "a ref local is stored as the reference's instance id")
	check(trigger.script_instance.get_local("ActivatorREF") == actor, "a ref local reads back as the same reference")
	var debug_instances: Array = server.get_debug_instances()
	var listed := false
	for entry in debug_instances:
		listed = listed or entry["reference"] == trigger
	check(listed, "debug instances list the reference")

	# IndDoorSmAnim01's script is `Begin OnActivate Player / Activate`.
	var door_base: EsmBase = esm_server.get_base(0x000463CE)
	var door := DoorReference.new()
	door.base = door_base
	door.instance_id = "test:door"
	server.player_reference = actor
	check(server.has_block_for(door, "OnActivate", actor), "OnActivate Player runs for the player's reference")
	check(actors.size() < 2 or not server.has_block_for(door, "OnActivate", actors[1]), "OnActivate Player does not run for another actor")

	# Console: `Player.Disable` acts on the player's node.
	var node := EsmNode.new()
	node.reference = actor
	add_child(node)
	var reply: Dictionary = server.run_debug_line("Player.Disable")
	check(bool(reply.get("ok", false)) and not node.visible, "console resolves Player to the player's reference and acts on its node")
	server.player_reference = null
	node.free()

	server.set_reference_loaded(trigger, true)
	server.set_reference_loaded(trigger, false)
	check(not server.is_reference_loaded(trigger), "an unloaded reference stops running GameMode")

	await _test_moves_and_names(esm_server, server)

## MoveTo / PositionCell / queued moves, and editor-ID names in scripts.
func _test_moves_and_names(esm_server, server) -> void:
	var doc: EsmReference = esm_server.find_reference_by_editor_id("DocMitchellREF")
	var marker: EsmReference = esm_server.find_reference_by_editor_id("REPHQ2ndTeleport1")
	check(doc != null and marker != null and EsmNode.node_for(doc) == null, "DocMitchellREF (unloaded) and REPHQ2ndTeleport1 resolve")
	if doc == null or marker == null:
		return
	var start_space := doc.current_space_form_id
	var start_position := doc.position
	var start_rotation := doc.rotation
	var events: Array = []
	var on_teleport := func(reference, old_space, new_space): if reference == doc: events.append([old_space, new_space])
	server.reference_teleported.connect(on_teleport)
	var run := func(source: String, ctx: ScriptExecutionContext) -> void:
		var program := ScriptParser.new(ScriptLexer.new("begin GameMode\n%s\nend" % source).tokenize()).parse()
		ScriptInterpreter.new(program, server.function_registry).run_block("GameMode", ctx)

	# MoveTo on a reference with no node: queued, then applied.
	run.call("MoveTo REPHQ2ndTeleport1 0 0 70", ScriptExecutionContext.new(doc))
	check(doc.current_space_form_id == start_space and not server.get_pending_move(doc).is_empty(), "MoveTo queues the move rather than applying it")
	server.apply_pending_moves()
	check(doc.current_space_form_id == marker.current_space_form_id and doc.position.is_equal_approx(marker.position + Vector3(0, 0, 1)),
			"MoveTo puts the reference at the marker's space and position plus the offset (70 units = 1 m)")
	check(doc.rotation == marker.rotation, "MoveTo takes the marker's rotation")
	check(doc.current_cell_form_id == esm_server.cell_at(marker.current_space_form_id, doc.position), "the moved reference's cell follows its new position")
	check(events == [[start_space, marker.current_space_form_id]], "reference_teleported reports the old and new space once")

	# Several moves in one frame: only the last is applied.
	events.clear()
	server.move_reference(doc, marker.current_space_form_id, marker.position + Vector3(5, 0, 0), Vector3.ZERO)
	server.move_reference(doc, start_space, start_position, start_rotation)
	server.apply_pending_moves()
	check(doc.current_space_form_id == start_space and doc.position == start_position and events.size() == 1, "moves queued in one frame collapse to the last")

	# PositionCell: Gamebryo units and degrees into a named CELL.
	events.clear()
	run.call("PositionCell 700 1400 70 90 GSDocMitchellHouse", ScriptExecutionContext.new(doc))
	server.apply_pending_moves()
	var interior := int(esm_server.reader.find_cell_by_editor_id("GSDocMitchellHouse").get("form_id", 0))
	check(doc.current_space_form_id == interior and doc.position.is_equal_approx(Vector3(10, 20, 1)) and is_equal_approx(doc.rotation.z, PI / 2),
			"PositionCell converts units and degrees and lands in the named CELL")
	server.move_reference(doc, start_space, start_position, start_rotation)
	server.apply_pending_moves()
	server.reference_teleported.disconnect(on_teleport)

	# Names resolve to placed references; another reference's variables are writable.
	var ctx := ScriptExecutionContext.new(null)
	ctx.action_ref = doc
	run.call("if (IsActionRef DocMitchellREF)\nset z to 1\nendif", ctx)
	check(ctx.get_local("z") == 1, "an editor-ID name in a script resolves to the placed reference")
	var writer := ScriptExecutionContext.new(null)
	run.call("set DocMitchellREF.PlayerLeft to 1\nset z to DocMitchellREF.PlayerLeft", writer)
	check(doc.script_instance != null and doc.script_instance.get_local("PlayerLeft") == 1, "set DocMitchellREF.PlayerLeft writes Doc Mitchell's own script variable")
	check(writer.get_local("z") == 1, "DocMitchellREF.PlayerLeft reads it back")

func _finish() -> void:
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
