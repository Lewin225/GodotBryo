class_name Inventory
extends RefCounted

## Plain runtime data: world ItemNodes are deliberately converted into this
## shape on pickup, rather than keeping a hidden scene node as inventory.
var _entries: Dictionary = {} # base FormID -> { count, full_name, value, weight, ... }

func add_item(base_form_id: int, item_data: Dictionary, count: int = 1) -> void:
	if base_form_id == 0 or count <= 0:
		return
	var entry: Dictionary = _entries.get(base_form_id, item_data.duplicate())
	entry["base_form_id"] = base_form_id
	entry["count"] = int(entry.get("count", 0)) + count
	_entries[base_form_id] = entry

func remove_item(base_form_id: int, count: int = 1) -> bool:
	if not _entries.has(base_form_id) or count <= 0:
		return false
	var entry: Dictionary = _entries[base_form_id]
	entry["count"] = int(entry["count"]) - count
	if int(entry["count"]) <= 0:
		_entries.erase(base_form_id)
	else:
		_entries[base_form_id] = entry
	return true

func get_entries() -> Array:
	return _entries.values()
