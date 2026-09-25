class_name ScriptExecutionContext
extends RefCounted

## State for one run of a script block. Built per dispatch and discarded; the
## persistent part (locals) lives in `instance`, which belongs to the calling
## reference.

## The reference the script belongs to (the implicit subject of calls such as
## `Enable`). Null for a context with no reference.
var calling_reference: EsmReference = null
## The reference that triggered this dispatch (GetActionRef / IsActionRef).
var action_ref: EsmReference = null
## The reference the `player` keyword resolves to. Null while no actor is
## possessed by the player; `player` then stays an unresolved name.
var player_reference: EsmReference = null
## Locals of the calling reference's script. A context without a reference
## gets a throwaway instance.
var instance: ScriptInstance = null

func _init(reference: EsmReference = null, script_instance: ScriptInstance = null) -> void:
	calling_reference = reference
	instance = script_instance if script_instance != null else ScriptInstance.new()

## A context for a call made on another reference (`OtherREF.Func`): that
## reference becomes the subject, while locals and the triggering references
## stay those of this dispatch.
func with_subject(reference: EsmReference) -> ScriptExecutionContext:
	var sub := ScriptExecutionContext.new(reference, instance)
	sub.action_ref = action_ref
	sub.player_reference = player_reference
	return sub

## Resolves a bare name in script source to a reference, or null: `player`
## is the player's reference; any other name is looked up as a placed
## reference's editor ID.
func resolve_reference_name(name: String) -> EsmReference:
	if name.to_lower() == "player":
		return player_reference
	var server := EsmReference.get_esm_server()
	if server == null or not server.is_ready():
		return null
	return server.find_reference_by_editor_id(name)

## Script truthiness: 0, including an unassigned `ref`, is false; anything
## else is true. Explicit per type because GDScript's bool() rejects Strings,
## which unresolved reference names evaluate to.
static func is_truthy(value: Variant) -> bool:
	if value == null:
		return false
	if value is Object:
		return true
	if value is String:
		return value != ""
	if value is int or value is float:
		return value != 0
	if value is bool:
		return value
	return true

## Equality that degrades to false across incompatible types instead of
## raising, as GDScript's == does for String vs Object or String vs int.
## Script values are int, float or reference; unresolved names are Strings.
static func safe_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) == typeof(b):
		return a == b
	var a_numeric := typeof(a) == TYPE_INT or typeof(a) == TYPE_FLOAT
	var b_numeric := typeof(b) == TYPE_INT or typeof(b) == TYPE_FLOAT
	if a_numeric and b_numeric:
		return float(a) == float(b)
	return false

func get_local(name: String) -> Variant:
	return instance.get_local(name)

func set_local(name: String, value: Variant) -> void:
	instance.set_local(name, value)

func has_local(name: String) -> bool:
	return instance.has_local(name)
