@tool
class_name InventoryComponent
extends Node

signal inventory_changed

## Generic composition component. It deliberately knows nothing about actors,
## containers, equipment slots, or rendering. Definitions are resolved ESM
## resources; mutable quantity and instance identity live in entries.
@export var entries: Array[InventoryEntryResource] = []
@export_category("Editor Helpers")
@export var editor_item_to_add: EsmRecordResource
@export_range(1, 999, 1) var editor_item_count: int = 1
@export var editor_item_equipped: bool = false
@export_tool_button("Add Item To Inventory") var add_item_button: Callable = _editor_add_item

var _next_instance_id: int = 1

func _editor_add_item() -> void:
	if editor_item_to_add == null or editor_item_to_add.form_id == 0:
		push_warning("InventoryComponent: drag an ESM item resource into editor_item_to_add first")
		return
	if not add_item(editor_item_to_add.form_id, editor_item_to_add, editor_item_count):
		return
	var added := entries[entries.size() - 1]
	if editor_item_equipped:
		added.is_equipped = true
	print("InventoryComponent: added ", editor_item_to_add.editor_id, " x", editor_item_count)

func set_authored_entries(authored: Array) -> void:
	entries.clear()
	var index := 0
	for source in authored:
		if not source is InventoryEntryResource:
			continue
		var entry: InventoryEntryResource = source
		if entry.instance_id.is_empty():
			entry.instance_id = "authored:%08X:%d" % [entry.item_form_id, index]
		entry.source_form_id = entry.item_form_id
		entry.source_index = index
		entries.append(entry)
		index += 1
	emit_signal("inventory_changed")

func add_item(item_form_id: int, item_record: EsmRecordResource = null, count: int = 1, instance_id: String = "") -> bool:
	if item_form_id == 0 or count <= 0:
		return false
	if instance_id.is_empty():
		for entry in entries:
			if entry.item_form_id == item_form_id and entry.instance_id.is_empty():
				entry.count += count
				emit_signal("inventory_changed")
				return true
	var entry := InventoryEntryResource.new()
	entry.item_form_id = item_form_id
	entry.item_record = item_record
	entry.count = count
	entry.instance_id = instance_id if not instance_id.is_empty() else _new_instance_id(item_form_id)
	entries.append(entry)
	emit_signal("inventory_changed")
	return true

func remove_item(item_form_id: int, count: int = 1, instance_id: String = "") -> bool:
	if count <= 0:
		return false
	for i in range(entries.size() - 1, -1, -1):
		var entry: InventoryEntryResource = entries[i]
		if entry.item_form_id != item_form_id:
			continue
		if not instance_id.is_empty() and entry.instance_id != instance_id:
			continue
		if entry.count < count:
			return false
		entry.count -= count
		if entry.count == 0:
			entries.remove_at(i)
		emit_signal("inventory_changed")
		return true
	return false

func has_item(item_form_id: int, count: int = 1) -> bool:
	return get_item_count(item_form_id) >= count

func get_item_count(item_form_id: int) -> int:
	var total := 0
	for entry in entries:
		if entry.item_form_id == item_form_id:
			total += entry.count
	return total

func set_equipped(instance_id: String, equipped: bool) -> bool:
	for entry in entries:
		if entry.instance_id != instance_id:
			continue
		entry.is_equipped = equipped
		emit_signal("inventory_changed")
		return true
	return false

func get_entries() -> Array[InventoryEntryResource]:
	return entries.duplicate()

func get_equipped_entries() -> Array[InventoryEntryResource]:
	var result: Array[InventoryEntryResource] = []
	for entry in entries:
		if entry.is_equipped:
			result.append(entry)
	return result

## Save boundary: only stable scalar identity/state is serialized. Resources
## are reconstructed from FormID by the active ESM resource factory on load.
func serialize_state() -> Dictionary:
	var serialized: Array[Dictionary] = []
	for entry in entries:
		serialized.append({
			"item_form_id": entry.item_form_id,
			"count": entry.count,
			"instance_id": entry.instance_id,
			"source_form_id": entry.source_form_id,
			"source_index": entry.source_index,
			"is_equipped": entry.is_equipped,
		})
	return {"version": 1, "entries": serialized}

func restore_state(state: Dictionary, record_resolver: Callable = Callable()) -> bool:
	var version := int(state.get("version", 0))
	if version != 1:
		return false
	entries.clear()
	for data in state.get("entries", []):
		if not data is Dictionary or int(data.get("item_form_id", 0)) == 0:
			continue
		var entry := InventoryEntryResource.new()
		entry.item_form_id = int(data.get("item_form_id", 0))
		entry.count = int(data.get("count", 0))
		entry.instance_id = String(data.get("instance_id", ""))
		entry.source_form_id = int(data.get("source_form_id", 0))
		entry.source_index = int(data.get("source_index", -1))
		entry.is_equipped = bool(data.get("is_equipped", false))
		if record_resolver.is_valid():
			entry.item_record = record_resolver.call(entry.item_form_id)
		if entry.count > 0:
			entries.append(entry)
	emit_signal("inventory_changed")
	return true

func clear() -> void:
	if entries.is_empty():
		return
	entries.clear()
	emit_signal("inventory_changed")

func _new_instance_id(item_form_id: int) -> String:
	var result := "runtime:%08X:%d" % [item_form_id, _next_instance_id]
	_next_instance_id += 1
	return result
