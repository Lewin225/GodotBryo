@tool
class_name InventoryItem
extends Resource

signal item_changed

## Not an ESM record: one entry of a live Inventory. An entry is either a
## stack (a base and a count, with no reference) or one item reference, which
## carries the item's own state. count and equipped state belong to the entry.

## Not an ESM field: the item's base FormID (CNTO or LVLO item, or the base of
## item_reference). Set when the entry is made; used by every reader that asks
## what the item is.
@export var base_form_id: int = 0
## Not an ESM field: the base resolved from base_form_id. Set with it; not
## saved, since the saved FormID resolves to it.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var base: EsmBase
## Not an ESM field: the item's own reference, a runtime reference from
## EsmServer.create_runtime_reference(); null for a stack. When the item becomes
## a reference is not decided (Plans/Completed Plans/Saving/save_load.md, Open), so nothing
## sets it yet outside tests.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmReference", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_STORAGE) var item_reference: EsmReference:
	set(value):
		item_reference = value
		if value != null:
			base_form_id = value.base_form_id
			base = value.base
@export var count: int = 1
@export var is_equipped: bool = false:
	set(value):
		if is_equipped == value:
			return
		is_equipped = value
		item_changed.emit()
## COED owner FormID from the CNTO or LVLO entry; 0 when none.
@export var owner_form_id: int = 0
## COED condition from the CNTO or LVLO entry; -1 when none.
@export var health_percent: float = -1.0
## Temporary derived compatibility data for the old player inventory UI.
var compatibility_data: Dictionary = {}


## A stack of `count` of `item_base`.
static func make_stack(item_base: EsmBase, item_count: int) -> InventoryItem:
	var item := InventoryItem.new()
	item.base = item_base
	item.base_form_id = item_base.form_id if item_base != null else 0
	item.count = item_count
	return item


## After SaveFields.read(): a stack resolves its base from base_form_id (a
## reference entry took its base from item_reference).
func _after_fields_read() -> void:
	if item_reference != null:
		return
	var server := EsmReference.get_esm_server()
	if server != null:
		base = server.get_base(base_form_id)
