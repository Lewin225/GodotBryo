@tool
class_name InventoryEntryResource
extends Resource

@export var item_form_id: int = 0
@export var count: int = 0
@export var item_record: EsmRecordResource
## Empty for authored stack entries; populated for uniquely instantiated
## runtime items and reserved for save/load identity.
@export var instance_id: String = ""
@export var source_form_id: int = 0
@export var source_index: int = -1
## Runtime state; authored CNTO records do not contain equipped state.
@export var is_equipped: bool = false
