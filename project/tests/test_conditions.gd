extends Node

## ConditionEvaluator against real data: comparisons, globals, Or grouping,
## Run On, unimplemented functions, script variables by SLSD index, and real
## terminal and quest conditions.

var failures := 0

func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1

## The CTDA function index of a condition function by name.
static func index_of(function_name: String) -> int:
	for index: int in ScriptConditionFunctions.BY_INDEX:
		if String(ScriptConditionFunctions.BY_INDEX[index][0]).to_lower() == function_name.to_lower():
			return index
	return -1

static func make(function_name: String, comparison: Condition.Comparison, value: float, parameter_1 := 0, parameter_2 := 0, flags := 0) -> Condition:
	var condition := Condition.new()
	condition.function_index = index_of(function_name)
	condition.comparison = comparison
	condition.comparison_value = value
	condition.parameter_1 = parameter_1
	condition.parameter_2 = parameter_2
	condition.flags = flags
	condition.has_run_on = true
	return condition

func _ready() -> void:
	var esm_server = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var server = get_node("/root/ScriptServer")
	var quests = get_node("/root/QuestServer")
	var eq := Condition.Comparison.EQUAL
	var none := ConditionContext.new()

	# Comparisons: GetStage on a quest set to stage 5.
	var vms20: QuestBase = esm_server.find_quest_by_editor_id("VMS20")
	quests.get_quest_state(vms20).stage = 5
	var expected := [true, false, false, true, false, true] # == != > >= < <=
	var results := []
	for comparison in 6:
		results.append(server.evaluate_conditions([make("GetStage", comparison, 5.0, vms20.form_id)] as Array[Condition], none))
	check(results == expected, "each comparison against GetStage VMS20 == 5 (%s)" % [results])
	check(server.evaluate_conditions([make("GetStage", Condition.Comparison.GREATER, 4.0, vms20.form_id)] as Array[Condition], none),
			"a quest-level function needs no subject")

	# A global comparison value: GetStage == CGHealTimer (120).
	var heal_timer: int = esm_server.find_form_id_by_editor_id("CGHealTimer")
	var global_condition := make("GetStage", eq, 0.0, vms20.form_id, 0, Condition.FLAG_USE_GLOBAL)
	global_condition.comparison_global_form_id = heal_timer
	quests.get_quest_state(vms20).stage = 120
	check(server.evaluate_conditions([global_condition] as Array[Condition], none), "Use Global compares with the GLOB's current value (120)")
	server.globals.set_global("CGHealTimer", 7)
	check(not server.evaluate_conditions([global_condition] as Array[Condition], none), "and follows it when the global changes")
	server.globals.set_global("CGHealTimer", 120)
	check(server.function_registry.call_function("GetGlobalValue", [esm_server.get_base(heal_timer)], ScriptExecutionContext.new(null)) == 120,
			"GetGlobalValue reads a global")

	# Or grouping: (a OR b) AND c; a trailing Or is ignored.
	quests.get_quest_state(vms20).stage = 5
	var yes := func(flags := 0) -> Condition: return make("GetStage", eq, 5.0, vms20.form_id, 0, flags)
	var no := func(flags := 0) -> Condition: return make("GetStage", eq, 6.0, vms20.form_id, 0, flags)
	check(server.evaluate_conditions([no.call(Condition.FLAG_OR), yes.call(), yes.call()] as Array[Condition], none), "(false OR true) AND true passes")
	check(not server.evaluate_conditions([no.call(Condition.FLAG_OR), no.call(), yes.call()] as Array[Condition], none), "(false OR false) AND true fails")
	check(not server.evaluate_conditions([yes.call(), no.call(Condition.FLAG_OR)] as Array[Condition], none), "a trailing Or does not rescue a false last condition")
	check(server.evaluate_conditions([yes.call(Condition.FLAG_OR), no.call()] as Array[Condition], none), "true OR false passes")
	check(server.evaluate_conditions([] as Array[Condition], none), "an empty list passes")

	# Run On: subject, target, a named reference (0x14 the player), none.
	var doc: EsmReference = esm_server.find_reference_by_editor_id("DocMitchellREF")
	var doc_base: int = doc.base_form_id
	var is_doc := make("GetIsID", eq, 1.0, doc_base)
	check(server.evaluate_conditions([is_doc] as Array[Condition], ConditionContext.new(doc)), "Run On Subject calls on the subject")
	var on_target := make("GetIsID", eq, 1.0, doc_base)
	on_target.run_on = Condition.RunOn.TARGET
	check(server.evaluate_conditions([on_target] as Array[Condition], ConditionContext.new(null, doc)), "Run On Target calls on the target")
	var on_player := make("GetIsReference", eq, 1.0, 0x14)
	on_player.run_on = Condition.RunOn.REFERENCE
	on_player.reference_form_id = 0x14
	check(server.evaluate_conditions([on_player] as Array[Condition], none), "Run On Reference 0x14 is the player")
	var on_combat := make("GetIsID", eq, 0.0, doc_base)
	on_combat.run_on = Condition.RunOn.COMBAT_TARGET
	check(not server.evaluate_conditions([on_combat] as Array[Condition], ConditionContext.new(doc)), "a Combat Target (none yet) makes the condition false")

	# Unimplemented functions read 0.
	check(server.evaluate_conditions([make("GetIsVoiceType", eq, 0.0)] as Array[Condition], ConditionContext.new(doc)), "an unimplemented function reads 0")

	# Script variables by SLSD index.
	var repcon: QuestBase = esm_server.find_quest_by_editor_id("RepconHQFreeform")
	var warning_index := -1
	for i in 64:
		if server.script_variable_name(repcon.script_form_id, i).to_lower() == "warningactive":
			warning_index = i
	check(warning_index >= 0, "RepconHQFreeform's script declares WarningActive (SLSD index %d)" % warning_index)
	server.get_quest_instance(repcon).set_local("WarningActive", 3)
	check(server.evaluate_conditions([make("GetQuestVariable", eq, 3.0, repcon.form_id, warning_index)] as Array[Condition], none),
			"GetQuestVariable reads a quest variable by SLSD index")
	server.get_quest_instance(repcon).set_local("WarningActive", 0)

	# A real terminal: V19OverseerWallTerminal's items follow its linked reference's open state.
	var terminal_ref: EsmReference = esm_server.get_reference("authored:00143990")
	var linked: EsmReference = esm_server.get_reference("authored:%08X" % terminal_ref.linked_reference_form_id)
	var terminal_base: TerminalBase = terminal_ref.base
	var disengage: TerminalMenuItem = terminal_base.menu_items[0]
	var engage: TerminalMenuItem = terminal_base.menu_items[1]
	var context := ConditionContext.new(esm_server.get_player_reference())
	context.linked_from = terminal_ref
	check(linked != null and "is_open" in linked, "the terminal's linked reference has an open state (%s)" % (linked.get_class() if linked != null else "missing"))
	if linked != null and "is_open" in linked:
		linked.set("is_open", false)
		check(server.evaluate_conditions(disengage.conditions, context) and not server.evaluate_conditions(engage.conditions, context),
				"closed: '%s' shows, '%s' does not" % [disengage.text.strip_edges(), engage.text.strip_edges()])
		linked.set("is_open", true)
		check(not server.evaluate_conditions(disengage.conditions, context) and server.evaluate_conditions(engage.conditions, context),
				"open: the reverse")
		linked.set("is_open", false)

	# A real quest log entry: VMQHouse4 stage 100 needs its GetGlobalValue global == 1.
	var house4: QuestBase = esm_server.find_quest_by_editor_id("VMQHouse4")
	var entry: QuestLogEntry = house4.get_stage(100).log_entries[0]
	var entry_global: EsmBase = esm_server.get_base(entry.conditions[0].parameter_1)
	server.globals.set_global(entry_global.editor_id, 0)
	check(not server.evaluate_conditions(entry.conditions, none), "VMQHouse4 stage 100's entry fails while %s is 0" % entry_global.editor_id)
	server.globals.set_global(entry_global.editor_id, 1)
	check(server.evaluate_conditions(entry.conditions, none), "and passes once it is 1")
	server.globals.set_global(entry_global.editor_id, 0)

	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
