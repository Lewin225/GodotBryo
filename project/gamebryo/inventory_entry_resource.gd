@tool
class_name InventoryEntryResource
extends Resource

@export var item_form_id: int = 0
@export var count: int = 0
@export var item_record: EsmRecordResource
## Rehydrated Base resource for the new ESM resource-backed paths. This is
## derived from item_form_id and intentionally not part of save identity.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var item_base: EsmBase
## Empty for authored stack entries; populated for uniquely instantiated
## runtime items and reserved for save/load identity.
@export var instance_id: String = ""
@export var source_form_id: int = 0
@export var source_index: int = -1
## Runtime state; authored CNTO records do not contain equipped state.
@export var is_equipped: bool = false
