class_name ConditionEvaluator
extends RefCounted

## Evaluates CTDA condition lists. Stateless: a condition only reads world
## state, through the same ScriptFunctionRegistry functions scripts call.
##
## Each condition calls its function (by CTDA index, ScriptConditionFunctions)
## on the reference its Run On names, with its parameters resolved, and
## compares the result with its value or its GLOB's current value.
## Conditions flagged Or form a group with the next condition, and the list
## passes when every group has a true condition: `a OR b` then `AND c`. An Or
## flag on the last condition has nothing to group with and is ignored. An
## unimplemented function reads 0, with one warning per function per owner.

var _server: Node
var _warned: Dictionary = {} # "function|owner" -> true

func _init(script_server: Node) -> void:
	_server = script_server

## Whether `conditions` pass for `context`. An empty list passes.
func evaluate(conditions: Array[ConditionSubrecord], context: ConditionContext) -> bool:
	var group_passed := false
	for i in conditions.size():
		var condition := conditions[i]
		group_passed = group_passed or evaluate_condition(condition, context)
		if condition.is_or() and i < conditions.size() - 1:
			continue
		if not group_passed:
			return false
		group_passed = false
	return true

## Whether one condition holds on its own, ignoring its Or flag. A condition
## whose Run On names a reference that does not exist (Reference, Linked
## Reference, Combat Target) is false; with no subject or target the function
## runs with no calling reference, as quest-level functions (GetStage) need
## none.
func evaluate_condition(condition: ConditionSubrecord, context: ConditionContext) -> bool:
	var subject := run_on_reference(condition, context)
	if subject == null and condition.run_on != ConditionSubrecord.RunOn.SUBJECT and condition.run_on != ConditionSubrecord.RunOn.TARGET:
		return false
	var name := ScriptConditionFunctions.name_for_index(condition.function_index)
	var registry: ScriptFunctionRegistry = _server.function_registry
	var value := 0.0
	if name.is_empty() or not registry.is_registered(name):
		_warn_unimplemented(name if not name.is_empty() else "#%d" % condition.function_index, context)
	else:
		var ctx := ScriptExecutionContext.new(subject)
		ctx.action_ref = context.target
		ctx.player_reference = _server.player_reference
		value = _number(registry.call_function(name, ScriptConditionFunctions.resolve_parameters(condition), ctx))
	return compare(value, condition.comparison, comparison_value(condition))

## The reference a condition's function runs on, or null (no subject or
## target, a Combat Target, a missing reference, no linked reference).
func run_on_reference(condition: ConditionSubrecord, context: ConditionContext) -> EsmReference:
	match condition.run_on:
		ConditionSubrecord.RunOn.SUBJECT:
			return context.subject
		ConditionSubrecord.RunOn.TARGET:
			return context.target
		ConditionSubrecord.RunOn.REFERENCE:
			return ScriptConditionFunctions.resolve_parameter("ptReference", condition.reference_form_id)
		ConditionSubrecord.RunOn.LINKED_REFERENCE:
			var source := context.linked_from if context.linked_from != null else context.subject
			if source == null or source.linked_reference_form_id == 0:
				return null
			return ScriptConditionFunctions.resolve_parameter("ptReference", source.linked_reference_form_id)
	return null

## The value a condition compares with: its GLOB's current value when it uses
## a global, else its comparison value.
func comparison_value(condition: ConditionSubrecord) -> float:
	if not condition.uses_global():
		return condition.comparison_value
	var esm_server := EsmReference.get_esm_server()
	var record: EsmBase = esm_server.get_base(condition.comparison_global_form_id) if esm_server != null else null
	if record == null:
		return 0.0
	return _number(_server.globals.get_global(record.editor_id))

static func compare(value: float, comparison: ConditionSubrecord.Comparison, against: float) -> bool:
	match comparison:
		ConditionSubrecord.Comparison.EQUAL: return is_equal_approx(value, against)
		ConditionSubrecord.Comparison.NOT_EQUAL: return not is_equal_approx(value, against)
		ConditionSubrecord.Comparison.GREATER: return value > against
		ConditionSubrecord.Comparison.GREATER_OR_EQUAL: return value >= against or is_equal_approx(value, against)
		ConditionSubrecord.Comparison.LESS: return value < against
		ConditionSubrecord.Comparison.LESS_OR_EQUAL: return value <= against or is_equal_approx(value, against)
	return false

## A function result as a number: bools as 0/1, a returned object as 1, null
## or anything else as 0.
static func _number(result: Variant) -> float:
	if result is float or result is int:
		return float(result)
	if result is bool:
		return 1.0 if result else 0.0
	if result is Object:
		return 1.0
	return 0.0

func _warn_unimplemented(function_name: String, context: ConditionContext) -> void:
	var key := "%s|%s" % [function_name, context.owner_label]
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning("ConditionEvaluator: unimplemented condition function '%s' on %s -- reads 0" % [function_name, context.owner_label if not context.owner_label.is_empty() else "an unnamed owner"])
