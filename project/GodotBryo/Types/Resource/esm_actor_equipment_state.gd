@tool
class_name EsmActorEquipmentState
extends Resource

## Typed equipment projection for an actor. This is a Godot runtime/editor
## convenience resource, not an ESM record.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "InventoryItem", PROPERTY_USAGE_EDITOR) var armor_items: Array[InventoryItem] = []
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "InventoryItem", PROPERTY_USAGE_EDITOR) var weapon_item: InventoryItem
@export var diagnostics: PackedStringArray = []

func get_armor_bases() -> Array[ArmorBase]:
	var result: Array[ArmorBase] = []
	for item in armor_items:
		if item != null and item.item_reference != null and item.item_reference.base is ArmorBase:
			result.append(item.item_reference.base as ArmorBase)
	return result

func get_weapon_base() -> WeaponBase:
	if weapon_item != null and weapon_item.item_reference != null and weapon_item.item_reference.base is WeaponBase:
		return weapon_item.item_reference.base as WeaponBase
	return null
