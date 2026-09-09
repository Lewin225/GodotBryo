@tool
class_name InventoryItem
extends Resource

signal item_changed

## Godot convenience resource for one live item in an Inventory. This is not
## an ESM record: item_reference is the typed item instance, while count and
## equipped state belong to its relationship with the owning inventory.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmReference", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_STORAGE) var item_reference: EsmReference
@export var count: int = 1
@export var instance_id: String = ""
@export var is_equipped: bool = false:
	set(value):
		if is_equipped == value:
			return
		is_equipped = value
		item_changed.emit()
## Temporary derived compatibility data for the old player inventory UI.
var compatibility_data: Dictionary = {}
