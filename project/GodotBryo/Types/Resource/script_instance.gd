@tool
class_name ScriptInstance
extends Resource

## The persistent state of one reference's object script: which SCPT runs and
## its local variables. Lives on the EsmReference, so it persists whether or
## not the reference is loaded and is saved with it. set_local() emits
## `changed`, which marks the reference dirty.

## SCPT FormID of the script this instance runs.
@export var script_form_id: int = 0
## Local variables, keyed by lowercased name. Values are int or float; a `ref`
## local holding a reference is stored as {"ref": instance_id} so a saved
## instance never embeds another reference.
@export var locals: Dictionary[String, Variant] = {}

## ScriptServer.clock when this script last ran; -1 before its first run.
## Runtime only: GetSecondsPassed measures from it.
var last_run_time: float = -1.0

func get_local(name: String) -> Variant:
	var value: Variant = locals.get(name.to_lower())
	if value is Dictionary and (value as Dictionary).has("ref"):
		var server := EsmReference.get_esm_server()
		return server.get_reference(String(value["ref"])) if server != null else null
	return value

func set_local(name: String, value: Variant) -> void:
	if value is EsmReference:
		locals[name.to_lower()] = {"ref": (value as EsmReference).instance_id}
	else:
		locals[name.to_lower()] = value
	emit_changed()

func has_local(name: String) -> bool:
	return locals.has(name.to_lower())
