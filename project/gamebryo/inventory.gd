@tool
class_name Inventory
extends Resource

## Godot convenience resource implementing live inventory state. This is not
## an ESM form. New callers use typed InventoryItem resources; get_entries()
## and the legacy add/remove overloads remain as a temporary compatibility
## projection for the existing player/debug path.
signal inventory_changed

@export_custom(PROPERTY_HINT_ARRAY_TYPE, "InventoryItem", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_STORAGE) var items: Array[InventoryItem] = []
var _next_instance_id: int = 1
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
		item = InventoryItem.new()
		item.item_reference = _make_compatibility_reference(form_id)
		item.count = count
		item.compatibility_data = payload.duplicate() if payload is Dictionary else {}
	return add_inventory_item(item)

func add_inventory_item(item: InventoryItem) -> bool:
	if item == null or item.item_reference == null or item.count <= 0:
		return false
	if item.instance_id.is_empty():
		item.instance_id = _new_instance_id(item.item_reference.base_form_id)
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
		if item != null and item.item_reference != null and item.item_reference.base_form_id == form_id:
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
		if item != null and item.item_reference != null and item.item_reference.base_form_id == form_id:
			total += item.count
	return total

func set_equipped(instance_id: String, equipped: bool) -> bool:
	for item in items:
		if item != null and item.instance_id == instance_id:
			return equip_item(item) if equipped else unequip_item(item)
	return false

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
		if item == null or item.item_reference == null:
			continue
		var entry: Dictionary = item.compatibility_data.duplicate()
		entry["base_form_id"] = item.item_reference.base_form_id
		entry["count"] = item.count
		entry["instance_id"] = item.instance_id
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
	return item != null and item.item_reference is ArmorReference \
			and item.item_reference.base is ArmorBase

func _equipment_conflicts(first: InventoryItem, second: InventoryItem) -> bool:
	if first.item_reference is WeaponReference and second.item_reference is WeaponReference:
		return true
	if _is_armor_item(first) and _is_armor_item(second):
		var first_flags := (first.item_reference.base as ArmorBase).biped_flags
		var second_flags := (second.item_reference.base as ArmorBase).biped_flags
		return first_flags != 0 and (first_flags & second_flags) != 0
	return false

func serialize_state() -> Dictionary:
	var saved: Array[Dictionary] = []
	for item in items:
		if item == null or item.item_reference == null:
			continue
		var reference := item.item_reference
		var state: Dictionary = {
			"base_form_id": reference.base_form_id,
			"reference_instance_id": reference.instance_id,
			"item_instance_id": item.instance_id,
			"count": item.count,
			"is_equipped": item.is_equipped,
			"owner_form_id": item.owner_form_id,
			"health_percent": item.health_percent,
		}
		if reference is WeaponReference:
			state["reference_type"] = "WeaponReference"
			state["condition"] = (reference as WeaponReference).condition
			state["loaded_ammo_form_id"] = (reference as WeaponReference).loaded_ammo_form_id
			state["loaded_ammo_count"] = (reference as WeaponReference).loaded_ammo_count
		elif reference is ArmorReference:
			state["reference_type"] = "ArmorReference"
			state["condition"] = (reference as ArmorReference).condition
		saved.append(state)
	return {"version": 1, "items": saved}

## Restores live typed item references through the supplied base/reference
## factory. CNTO is intentionally not involved in this path.
func restore_state(state: Dictionary, reference_factory: Callable) -> bool:
	if int(state.get("version", 0)) != 1 or not reference_factory.is_valid():
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
		var reference = reference_factory.call(form_id, String(data.get("reference_instance_id", "")))
		if not reference is EsmReference:
			continue
		var typed_reference: EsmReference = reference
		if typed_reference is WeaponReference:
			var weapon := typed_reference as WeaponReference
			weapon.condition = float(data.get("condition", -1.0))
			weapon.loaded_ammo_form_id = int(data.get("loaded_ammo_form_id", 0))
			weapon.loaded_ammo_count = int(data.get("loaded_ammo_count", 0))
		elif typed_reference is ArmorReference:
			(typed_reference as ArmorReference).condition = float(data.get("condition", -1.0))
		var item := InventoryItem.new()
		item.item_reference = typed_reference
		item.instance_id = String(data.get("item_instance_id", ""))
		item.count = int(data.get("count", 0))
		item.is_equipped = bool(data.get("is_equipped", false))
		item.owner_form_id = int(data.get("owner_form_id", 0))
		item.health_percent = float(data.get("health_percent", -1.0))
		if item.count > 0:
			items.append(item)
			_connect_item(item)
	inventory_changed.emit()
	return true

func _make_compatibility_reference(form_id: int) -> EsmReference:
	var reference := EsmReference.new()
	reference.base_form_id = form_id
	reference.instance_id = _new_instance_id(form_id) + ":ref"
	return reference

func _new_instance_id(form_id: int) -> String:
	var result := "inventory:%08X:%d" % [form_id, _next_instance_id]
	_next_instance_id += 1
	return result
