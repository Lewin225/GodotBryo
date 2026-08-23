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
## The real player character, if one exists (set by ScriptEngine.dispatch_event()
## from its own player_node -- real GECK's "player" is a global keyword
## resolving to the actual player reference, distinct from action_ref: a
## script triggered by an NPC's OnTriggerEnter, say, has a real action_ref
## that ISN'T the player at all). Null in any context with no live player
## (most tests, @tool viewers) -- "player" then just stays an unresolved
## name, same as any other reference this interpreter can't look up yet.
var player_node: Node = null
var locals: Dictionary = {} # name (lowercased) -> int/float/Node/null

func _init(reference: Node = null) -> void:
	calling_reference = reference

## Real language rule (design doc's Variables section): 0, including an
## unassigned `ref`, is false; anything else is true. Explicit per-type
## checks, not a blind `bool(value)` cast -- confirmed directly this
## session (a real crash in real play, "SPECIAL machine" script content):
## GDScript's own `bool()` constructor is just as strict as `String()` and
## `==` already turned out to be, and throws "Nonexistent 'bool'
## constructor" for a String (a "name" AST node's own unresolved-ref
## literal -- script_parser.gd's own doc comment) rather than the lenient
## "any non-empty value is true" a real runtime fallback needs here.
static func is_truthy(value: Variant) -> bool:
	if value == null:
		return false
	if value is Node:
		return true
	if value is String:
		return value != ""
	if value is int or value is float:
		return value != 0
	if value is bool:
		return value
	return true # any other real, non-null Variant this interpreter produces counts as "exists" -- see is_truthy's own doc comment

## Shared by ScriptInterpreter's own `==`/`!=` binop AND any registered
## function that compares a caller-supplied value against a live reference
## (IsActionRef, ...) -- real Gamebryo/GECK has exactly three value types
## (int/float/ref) and its compiler rejects a type-mismatched comparison
## outright, so a real script never actually compares across incompatible
## types. This interpreter can transiently produce one anyway (a "name"
## AST node standing in for an unresolved `ref` as a plain String --
## script_parser.gd's own doc comment), and GDScript's own `==`/`!=` throw
## for genuinely incompatible Variant type PAIRS -- confirmed directly this
## session for both String-vs-int and String-vs-Object ("Invalid operands"),
## not just returning false the way a safe runtime fallback should. This
## degrades to "not equal" instead, matching how a real Gamebryo runtime
## would never even reach this comparison in valid compiled code.
static func safe_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) == typeof(b):
		return a == b
	var a_numeric := typeof(a) == TYPE_INT or typeof(a) == TYPE_FLOAT
	var b_numeric := typeof(b) == TYPE_INT or typeof(b) == TYPE_FLOAT
	if a_numeric and b_numeric:
		return float(a) == float(b)
	return false

func get_local(name: String) -> Variant:
	return locals.get(name.to_lower())

func set_local(name: String, value: Variant) -> void:
	locals[name.to_lower()] = value

func has_local(name: String) -> bool:
	return locals.has(name.to_lower())
