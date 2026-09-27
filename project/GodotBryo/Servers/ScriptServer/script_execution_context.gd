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
## Real seconds since this script last ran, as GetSecondsPassed returns; 0 on
## its first run.
var seconds_passed: float = 0.0

func _init(ref: EsmReference = null, script_instance: ScriptInstance = null) -> void:
	calling_reference = ref
	instance = script_instance if script_instance != null else ScriptInstance.new()

## The running script and the reference it acts on, for diagnostics:
## `script VMS11DazzleNoteSCRIPT (SCPT 0010ABCD) on authored:0014AF3E (Base)`.
## A result script or console line has no SCPT and says so.
func describe() -> String:
	var script_form_id := instance.script_form_id if instance != null else 0
	var text := "a result script or console line"
	if script_form_id != 0:
		var esm_server := EsmReference.get_esm_server()
		var script_base: EsmBase = esm_server.get_base(script_form_id) if esm_server != null and esm_server.is_ready() else null
		var editor_id := script_base.editor_id if script_base != null and script_base.editor_id != "" else "?"
		text = "script %s (SCPT %08X)" % [editor_id, script_form_id]
	if calling_reference != null:
		var base_name := calling_reference.base.editor_id if calling_reference.base != null else ""
		text += " on %s" % calling_reference.instance_id
		if base_name != "":
			text += " (%s)" % base_name
	return text

## A context for a call made on another reference (`OtherREF.Func`): that
## reference becomes the subject, while locals and the triggering references
## stay those of this dispatch.
func with_subject(ref: EsmReference) -> ScriptExecutionContext:
	var sub := ScriptExecutionContext.new(ref, instance)
	sub.action_ref = action_ref
	sub.player_reference = player_reference
	sub.seconds_passed = seconds_passed
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
