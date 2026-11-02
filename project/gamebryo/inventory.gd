@tool
class_name Inventory
extends Resource

## Godot convenience resource implementing live inventory state. This is not
## an ESM form. New callers use typed InventoryItem resources; get_entries()
## and the legacy add/remove overloads remain as a temporary compatibility
## projection for the existing player/debug path.
signal inventory_changed

@export_custom(PROPERTY_HINT_ARRAY_TYPE, "InventoryItem", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_STORAGE) var items: Array[InventoryItem] = []
var _batch_depth: int = 0
var _batch_dirty: bool = false

func add_item(item_or_form_id: Variant, payload: Variant = null, count: int = 1) -> bool:
	var item: InventoryItem
	if item_or_form_id is InventoryItem:
		item = item_or_form_id as InventoryItem
	else:
		var form_id := int(item_or_form_id)
		if form_id == 0 or count <= 0:
			return false
		item = InventoryItem.make_stack(_get_base(form_id), count)
		item.base_form_id = form_id
		item.compatibility_data = payload.duplicate() if payload is Dictionary else {}
	return add_inventory_item(item)

func add_inventory_item(item: InventoryItem) -> bool:
	if item == null or item.base_form_id == 0 or item.count <= 0:
		return false
	items.append(item)
	_connect_item(item)
	_emit_changed()
	return true

func remove_item(item_or_form_id: Variant, count: int = 1) -> bool:
	if count <= 0:
		return false
	if item_or_form_id is InventoryItem:
		return remove_inventory_item(item_or_form_id as InventoryItem, count)
	var form_id := int(item_or_form_id)
	for item in items:
		if item != null and item.base_form_id == form_id:
			return remove_inventory_item(item, count)
	return false

func remove_inventory_item(item: InventoryItem, count: int = 1) -> bool:
	if item == null or count <= 0 or not items.has(item) or item.count < count:
		return false
	item.count -= count
	if item.count == 0:
		_disconnect_item(item)
		items.erase(item)
	_emit_changed()
	return true

func has_item(form_id: int, count: int = 1) -> bool:
	return get_item_count(form_id) >= count

func get_item_count(form_id: int) -> int:
	var total := 0
	for item in items:
		if item != null and item.base_form_id == form_id:
			total += item.count
	return total

func equip_item(item: InventoryItem) -> bool:
	if item == null or not items.has(item):
		return false
	begin_batch()
	for other in items:
		if other != null and other != item and other.is_equipped and _equipment_conflicts(item, other):
			other.is_equipped = false
	item.is_equipped = true
	end_batch()
	return true

func unequip_item(item: InventoryItem) -> bool:
	if item == null or not items.has(item):
		return false
	begin_batch()
	item.is_equipped = false
	end_batch()
	return true

func equip_default_armor() -> void:
	# NPC authored inventory has no equipped flag. Later conflicting armor
	# entries win, matching the existing equipment resolver priority.
	begin_batch()
	for item in items:
		if _is_armor_item(item):
			for other in items:
				if other != null and other != item and other.is_equipped and _equipment_conflicts(item, other):
					other.is_equipped = false
			item.is_equipped = true
	end_batch()

func begin_batch() -> void:
	_batch_depth += 1

func end_batch() -> void:
	_batch_depth = maxi(0, _batch_depth - 1)
	if _batch_depth == 0 and _batch_dirty:
		_batch_dirty = false
		inventory_changed.emit()

func get_items() -> Array[InventoryItem]:
	return items.duplicate()

func get_equipped_items() -> Array[InventoryItem]:
	var result: Array[InventoryItem] = []
	for item in items:
		if item != null and item.is_equipped:
			result.append(item)
	return result

## Compatibility view for old player/debug callers. It is derived from items.
func get_entries() -> Array:
	var result: Array = []
	for item in items:
		if item == null:
			continue
		var entry: Dictionary = item.compatibility_data.duplicate()
		entry["base_form_id"] = item.base_form_id
		entry["count"] = item.count
		result.append(entry)
	return result

func clear() -> void:
	if items.is_empty():
		return
	for item in items:
		if item != null:
			_disconnect_item(item)
	items.clear()
	_batch_dirty = false
	inventory_changed.emit()

func _connect_item(item: InventoryItem) -> void:
	if not item.item_changed.is_connected(_on_item_changed):
		item.item_changed.connect(_on_item_changed)

func _disconnect_item(item: InventoryItem) -> void:
	if item.item_changed.is_connected(_on_item_changed):
		item.item_changed.disconnect(_on_item_changed)

func _on_item_changed() -> void:
	_emit_changed()

func _emit_changed() -> void:
	if _batch_depth > 0:
		_batch_dirty = true
	else:
		inventory_changed.emit()

func _is_armor_item(item: InventoryItem) -> bool:
	return item != null and item.base is ArmorBase

func _equipment_conflicts(first: InventoryItem, second: InventoryItem) -> bool:
	if first.base is WeaponBase and second.base is WeaponBase:
		return true
	if _is_armor_item(first) and _is_armor_item(second):
		var first_flags := (first.base as ArmorBase).biped_flags
		var second_flags := (second.base as ArmorBase).biped_flags
		return first_flags != 0 and (first_flags & second_flags) != 0
	return false

## The inventory as plain values: a stack by its base FormID, a reference
## entry by its reference's instance_id.
func serialize_state() -> Dictionary:
	var saved: Array[Dictionary] = []
	for item in items:
		if item == null:
			continue
		var state: Dictionary = {
			"base_form_id": item.base_form_id,
			"count": item.count,
			"is_equipped": item.is_equipped,
			"owner_form_id": item.owner_form_id,
			"health_percent": item.health_percent,
		}
		if item.item_reference != null:
			state["reference_instance_id"] = item.item_reference.instance_id
		saved.append(state)
	return {"version": 2, "items": saved}

## Restores serialize_state()'s output. A reference entry's reference comes
## from `reference_lookup` (instance_id -> EsmReference); an entry whose
## reference it cannot find is dropped.
func restore_state(state: Dictionary, reference_lookup: Callable) -> bool:
	if int(state.get("version", 0)) != 2 or not reference_lookup.is_valid():
		return false
	for existing in items:
		if existing != null:
			_disconnect_item(existing)
	items.clear()
	for data in state.get("items", []):
		if not data is Dictionary:
			continue
		var form_id := int(data.get("base_form_id", 0))
		if form_id == 0:
			continue
		var item := InventoryItem.make_stack(_get_base(form_id), int(data.get("count", 0)))
		item.base_form_id = form_id
		var reference_id := String(data.get("reference_instance_id", ""))
		if not reference_id.is_empty():
			var item_ref = reference_lookup.call(reference_id)
			if not item_ref is EsmReference:
				continue
			item.item_reference = item_ref
		item.is_equipped = bool(data.get("is_equipped", false))
		item.owner_form_id = int(data.get("owner_form_id", 0))
		item.health_percent = float(data.get("health_percent", -1.0))
		if item.count > 0:
			items.append(item)
			_connect_item(item)
	inventory_changed.emit()
	return true

## The base of `form_id` from EsmServer, or null when EsmServer is not running.
func _get_base(form_id: int) -> EsmBase:
	var server := EsmReference.get_esm_server()
	if server == null:
		return null
	return server.get_base(form_id)
