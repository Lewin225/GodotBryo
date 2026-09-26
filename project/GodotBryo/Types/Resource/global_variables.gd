@tool
class_name GlobalVariables
extends Resource

## The values of the game's global variables (GLOB records), by lowercased
## editor ID. A global enters `values` the first time it is read or written,
## seeded from its authored value; short and long globals hold ints, float
## globals floats. Saving this saves every global the game has touched.

@export var values: Dictionary = {}

## Editor IDs known not to be globals, so repeated lookups of other names stay
## in memory. Not saved.
var _not_globals: Dictionary = {}
## Lowercased editor ID -> "s", "l" or "f". Not saved; re-read from the ESM.
var _types: Dictionary = {}

## Whether `name` is a global variable.
func has_global(name: String) -> bool:
	return _resolve(name.to_lower())

## A global's value, or null when `name` is not a global.
func get_global(name: String) -> Variant:
	var key := name.to_lower()
	return values[key] if _resolve(key) else null

## Sets a global. Returns false when `name` is not a global.
func set_global(name: String, value: Variant) -> bool:
	var key := name.to_lower()
	if not _resolve(key):
		return false
	var number := float(value) if (value is int or value is float) else 0.0
	values[key] = number if _types.get(key, "f") == "f" else int(number)
	return true

## Ensures `key` is in `values` if it is a global; false when it is not.
func _resolve(key: String) -> bool:
	if values.has(key) and _types.has(key):
		return true
	if _not_globals.has(key):
		return false
	var esm_server := EsmReference.get_esm_server()
	if esm_server == null or not esm_server.is_ready():
		return false
	var record: Dictionary = esm_server.find_global_by_editor_id(key)
	if record.is_empty():
		_not_globals[key] = true
		return false
	_types[key] = String(record.get("type", "f"))
	if not values.has(key):
		var authored := float(record.get("value", 0.0))
		values[key] = authored if _types[key] == "f" else int(authored)
	return true
