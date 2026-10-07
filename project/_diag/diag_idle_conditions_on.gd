extends Node

## Evaluates each condition of an IDLE (first argument) on a placed actor
## (second argument, editor ID), one at a time, with the names of any forms
## the parameters name.
func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var args := OS.get_cmdline_user_args()
	var idle := EsmServer.find_base_by_editor_id(args[0]) as IdleBase
	var actor := EsmServer.find_reference_by_editor_id(args[1])
	for condition in idle.conditions:
		var entry: Array = ScriptConditionFunctions.BY_INDEX.get(condition.function_index, ["#%d" % condition.function_index, []])
		var single: Array[ConditionSubrecord] = [condition]
		var named := EsmServer.get_base(condition.parameter_1)
		var passes := ScriptServer.evaluate_conditions(single, ConditionContext.new(actor))
		print("%s %s %s (p1 %08X %s): %s" % [entry[0], ["==", "!=", ">", ">=", "<", "<="][condition.comparison], condition.comparison_value, condition.parameter_1, named.editor_id if named != null else "", passes])
	get_tree().quit()
