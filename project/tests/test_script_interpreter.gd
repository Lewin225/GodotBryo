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

	_test_moves_and_names(esm_server, server)
	_test_quests_and_messages(esm_server, server)
	_test_globals(server)
	_test_parsing_and_return(server)
	_test_items_and_location(esm_server, server)

## Inventory, identity, location and open-state functions on real references.
func _test_items_and_location(esm_server, server) -> void:
	var doc: EsmReference = esm_server.find_reference_by_editor_id("DocMitchellREF")
	var run := func(line: String, target: EsmReference) -> Variant:
		return server.run_debug_line(line, target).get("result")
	var start_count: int = run.call("GetItemCount Stimpak", doc)
	run.call("AddItem Stimpak 3", doc)
	check(run.call("GetItemCount Stimpak", doc) == start_count + 3, "AddItem / GetItemCount (Stimpak +3)")
	run.call("RemoveItem Stimpak 2", doc)
	check(run.call("GetItemCount Stimpak", doc) == start_count + 1, "RemoveItem removes the count asked for")
	var added: EsmBase = doc.contents.get_items().back().item_reference.base
	check(added is AlchemyBase, "added items are typed references (%s)" % added.get_class())

	var leveled: LeveledItemBase = null
	for row: Dictionary in esm_server.get_record_index():
		if String(row.get("record_type", "")) == "LVLI":
			leveled = esm_server.get_base(int(row["form_id"])) as LeveledItemBase
			if leveled != null and not leveled.editor_id.is_empty() and not leveled.entries.is_empty():
				break
	var before: int = doc.contents.get_items().size()
	server.run_debug_line("AddItem %s 1" % leveled.editor_id, doc)
	var from_list: InventoryItem = doc.contents.get_items().back() if doc.contents.get_items().size() > before else null
	check(from_list == null or not from_list.item_reference.base is LeveledItemBase,
			"AddItem with a leveled list adds what it resolves to, never the list (%s)" % leveled.editor_id)

	run.call("EquipItem Stimpak", doc)
	check(run.call("GetEquipped Stimpak", doc) == 1, "EquipItem / GetEquipped")
	run.call("UnequipItem Stimpak", doc)
	check(run.call("GetEquipped Stimpak", doc) == 0, "UnequipItem")

	var locker := ContainerReference.new()
	locker.contents = Inventory.new()
	var carried: int = doc.contents.get_items().size()
	var removed_all: Dictionary = server.run_debug_line("RemoveAllItems", doc)
	check(bool(removed_all.get("ok")) and doc.contents.get_items().is_empty(), "RemoveAllItems with no target empties the inventory (%d items)" % carried)
	run.call("AddItem Stimpak 2", doc)
	var moved := ScriptExecutionContext.new(doc)
	server.function_registry.call_function("RemoveAllItems", [locker], moved)
	check(doc.contents.get_items().is_empty() and locker.contents.get_item_count(esm_server.find_base_by_editor_id("Stimpak").form_id) == 2,
			"RemoveAllItems Target moves every item to the target")

	check(run.call("GetIsID DocMitchell", doc) == 1 and run.call("GetIsID Stimpak", doc) == 0, "GetIsID compares the base")
	check(run.call("GetIsReference DocMitchellREF", doc) == 1 and run.call("GetIsReference player", doc) == 0, "GetIsReference")
	check(run.call("GetInCell GSDocMitchellHouse", doc) == 1 and run.call("GetInCell GSProspectorSaloonInterior", doc) == 0, "GetInCell matches the CELL")
	check(run.call("GetInWorldspace WastelandNV", doc) == 0, "an interior reference is in no worldspace")
	var tester: EsmReference = esm_server.find_reference_by_editor_id("VCG01VigorTesterREF")
	check(run.call("GetInSameCell VCG01VigorTesterREF", doc) == 1, "GetInSameCell")
	var expected := doc.position.distance_to(tester.position) * 70.0
	check(absf(float(run.call("GetDistance VCG01VigorTesterREF", doc)) - expected) < 1.0, "GetDistance in Gamebryo units (%.1f)" % expected)
	check(float(run.call("GetDistance VictorREF", doc)) >= 1.0e9, "GetDistance across spaces is very large")

	var door: DoorReference = esm_server.find_reference_by_editor_id("V21PlayerRoomDoorREF") as DoorReference
	check(door != null and door.teleport == null, "V21PlayerRoomDoorREF is a non-teleport door")
	run.call("SetOpenState 1", door)
	check(door.is_open and run.call("GetOpenState", door) == 1, "SetOpenState 1 opens; GetOpenState 1")
	run.call("SetOpenState 0", door)
	check(not door.is_open and run.call("GetOpenState", door) == 3, "SetOpenState 0 closes; GetOpenState 3")
	check(run.call("GetLocked", door) == int(door.is_locked), "GetLocked reads the lock")
	run.call("MarkForDelete", door)
	check(door.marked_for_delete, "MarkForDelete marks the reference")
	door.marked_for_delete = false

## Condition functions take their arguments inside expressions, trailing
## arguments may be omitted, and Return ends the run.
func _test_parsing_and_return(server) -> void:
	var parse := func(source: String) -> Dictionary:
		return ScriptParser.new(ScriptLexer.new(source).tokenize()).parse()
	var program: Dictionary = parse.call("begin GameMode\nif GetReputation RepNVNCR 1 > 5\nset a to 1\nendif\nend")
	var branch: Dictionary = program["blocks"][0]["stmts"][0]["branches"][0]
	var cond: Dictionary = branch["cond"]
	check(cond["kind"] == "binop" and cond["op"] == ">" and cond["left"]["kind"] == "call" and (cond["left"]["args"] as Array).size() == 2,
			"a condition function consumes its arguments inside an expression (GetReputation RepNVNCR 1 > 5)")
	check((branch["stmts"] as Array).size() == 1 and branch["stmts"][0]["kind"] == "set",
			"its arguments no longer spill into the if body as statements")
	program = parse.call("begin GameMode\nif HasPerk SomePerk == 1\nset a to 1\nendif\nend")
	cond = program["blocks"][0]["stmts"][0]["branches"][0]["cond"]
	check(cond["kind"] == "binop" and cond["op"] == "==" and (cond["left"]["args"] as Array).size() == 1,
			"an omitted trailing argument leaves the following operator alone (HasPerk SomePerk == 1)")
	program = parse.call("begin GameMode\nset a to GetPCMiscStat \"Times Addicted\"\nend")
	var misc: Dictionary = program["blocks"][0]["stmts"][0]["expr"]
	check(misc["kind"] == "call" and misc["args"][0]["value"] == "Times Addicted", "a quoted argument belongs to its call")

	var ctx := ScriptExecutionContext.new(null)
	var interpreter := ScriptInterpreter.new(parse.call("short a\nshort b\nbegin GameMode\nset a to 1\nif a\nreturn\nendif\nset a to 2\nend\nbegin GameMode\nset b to 1\nend"), server.function_registry)
	interpreter.run_block("GameMode", ctx)
	check(ctx.get_local("a") == 1 and not ctx.has_local("b"), "Return ends the run: no later statement or block runs")
	var again := ScriptExecutionContext.new(null)
	ScriptInterpreter.new(parse.call("short a\nbegin GameMode\nset a to 0\nif a\nreturn\nendif\nset a to 2\nend"), server.function_registry).run_block("GameMode", again)
	check(again.get_local("a") == 2, "a Return not reached does nothing")

## Global variables (GLOB): read, written, typed, and not confused with locals.
func _test_globals(server) -> void:
	var run := func(source: String, run_ctx: ScriptExecutionContext) -> void:
		var program := ScriptParser.new(ScriptLexer.new(source).tokenize()).parse()
		ScriptInterpreter.new(program, server.function_registry).run_block("GameMode", run_ctx)
	var ctx := ScriptExecutionContext.new(null)
	run.call("begin GameMode\nset z to CGHealTimer\nend", ctx)
	check(ctx.get_local("z") == 120, "a script reads a global's authored value (CGHealTimer = 120)")
	run.call("begin GameMode\nset CGHealTimer to 7.9\nend", ScriptExecutionContext.new(null))
	check(server.globals.get_global("CGHealTimer") == 7, "writing a short global stores an int")
	check(server.globals.values.has("cghealtimer"), "the written value is held in GlobalVariables")
	var declared := ScriptExecutionContext.new(null)
	run.call("float CGHealTimer\nbegin GameMode\nset CGHealTimer to 3\nend", declared)
	check(declared.get_local("CGHealTimer") == 3 and server.globals.get_global("CGHealTimer") == 7,
			"a script that declares a local with a global's name writes its local")
	check(not server.globals.has_global("GSBrokenSMGMsg") and not server.globals.has_global("GSBrokenSMGMsg"), "a non-global name is not a global (cached)")
	server.globals.set_global("CGHealTimer", 120)

	# GetSecondsPassed is per script: real seconds since that script last ran.
	var instance := ScriptInstance.new()
	server._start_run(ScriptExecutionContext.new(null, instance))
	instance.last_run_msec -= 1500
	var probe := ScriptExecutionContext.new(null, instance)
	server._start_run(probe)
	check(absf(probe.seconds_passed - 1.5) < 0.1, "GetSecondsPassed is the real time since this script last ran (%.2f s)" % probe.seconds_passed)
	var other_probe := ScriptExecutionContext.new(null, ScriptInstance.new())
	server._start_run(other_probe)
	check(other_probe.seconds_passed == 0.0, "another script's first run starts at 0, unaffected")

## Quest variables, per-reference message buttons, and the Lucky 38 elevator.
func _test_quests_and_messages(esm_server, server) -> void:
	var run := func(source: String, run_ctx: ScriptExecutionContext) -> void:
		var program := ScriptParser.new(ScriptLexer.new("begin GameMode\n%s\nend" % source).tokenize()).parse()
		ScriptInterpreter.new(program, server.function_registry).run_block("GameMode", run_ctx)
	var ctx := ScriptExecutionContext.new(null)
	run.call("set RepconHQFreeform.WarningActive to 1\nset z to RepconHQFreeform.WarningActive", ctx)
	var quest: EsmBase = esm_server.find_quest_by_editor_id("RepconHQFreeform")
	check(server.get_quest_instance(quest) != null and server.get_quest_instance(quest).get_local("WarningActive") == 1, "a quest variable is written to the quest's script")
	check(ctx.get_local("z") == 1, "and reads back")

	var shower := ActivatorReference.new()
	var other := ActivatorReference.new()
	server._handle_show_message({}, ScriptExecutionContext.new(shower))
	server._on_message_box_button_clicked(4)
	check(server._handle_get_button_pressed(ScriptExecutionContext.new(other)) == -1, "another reference's GetButtonPressed does not see the click")
	check(server._handle_get_button_pressed(ScriptExecutionContext.new(shower)) == 4, "the reference that showed the message gets the button")
	check(server._handle_get_button_pressed(ScriptExecutionContext.new(shower)) == -1, "once")

	# The Lucky 38 elevator: OnActivate shows the floor menu, GameMode moves the
	# player on the chosen button (4 = Casino).
	var player_ref: ActorReference = esm_server.get_player_reference()
	var elevator: EsmReference = esm_server.find_reference_by_editor_id("Lucky38ElevatorDoorBaseREF")
	var casino: EsmReference = esm_server.find_reference_by_editor_id("Lucky38CasinoFloorMarker")
	server.player_reference = player_ref
	server.activate(elevator, player_ref)
	check(server._message_owner != elevator, "at a fresh game the casino elevator shows nothing (gated on VMQ02 stage 10)")
	run.call("SetStage VMQ02 10", ScriptExecutionContext.new(null))
	check(get_node("/root/QuestServer").get_stage(esm_server.find_quest_by_editor_id("VMQ02")) == 10, "SetStage sets a quest's stage")
	server.activate(elevator, player_ref)
	check(server._message_owner == elevator, "once VMQ02 reaches stage 10, activating the elevator shows its floor menu")
	server._on_message_box_button_clicked(4)
	server.dispatch_event(elevator, "GameMode")
	var move: Dictionary = server.get_pending_move(player_ref)
	check(casino != null and int(move.get("space_form_id", 0)) == casino.current_space_form_id and move.get("position") == casino.position,
			"choosing Casino moves the player to Lucky38CasinoFloorMarker")
	server._pending_moves.erase(player_ref)
	server.player_reference = null

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
	var run := func(source: String, run_ctx: ScriptExecutionContext) -> void:
		var program := ScriptParser.new(ScriptLexer.new("begin GameMode\n%s\nend" % source).tokenize()).parse()
		ScriptInterpreter.new(program, server.function_registry).run_block("GameMode", run_ctx)

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
