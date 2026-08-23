class_name ScriptExecutionContext
extends RefCounted

## Per-instance state for one running script -- one of these per (script,
## calling reference) pair, per nv_script_interpreter_design.md's Execution
## model / Variables sections. `calling_reference` is the GamebryoReference
## Node this Object script is attached to (null for a future Quest-script
## context, which has no reference of its own -- see the design doc's
## "Quest" row in its Variables table). `action_ref` is whichever
## reference triggered the CURRENT event dispatch (the entity GetActionRef/
## IsActionRef read) -- set fresh by ScriptEngine.dispatch_event() each
## time, not persistent script state.

var calling_reference: Node = null
var action_ref: Node = null
var locals: Dictionary = {} # name (lowercased) -> int/float/Node/null

func _init(reference: Node = null) -> void:
	calling_reference = reference

## Real language rule (design doc's Variables section): 0, including an
## unassigned `ref`, is false; anything else is true.
static func is_truthy(value: Variant) -> bool:
	if value == null:
		return false
	if value is Node:
		return true
	return bool(value)

func get_local(name: String) -> Variant:
	return locals.get(name.to_lower())

func set_local(name: String, value: Variant) -> void:
	locals[name.to_lower()] = value

func has_local(name: String) -> bool:
	return locals.has(name.to_lower())
