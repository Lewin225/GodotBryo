@tool
class_name ContainerReference
extends EsmReference

## REFR XACT activation flags and current container state.
@export var activation_flags: int = 0
@export var is_open: bool = false
## Runtime/authored overrides are composed into the node's InventoryComponent.
@export var contents: Array[InventoryEntryResource] = []
