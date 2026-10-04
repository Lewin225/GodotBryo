@tool
class_name ContainerReference
extends EsmReference

## REFR XACT activation flags and current container state.
@export var activation_flags: int = 0
@export var is_open: bool = false
## Live inventory aggregate. CNTO is used only when this is first created.
@export var contents: Inventory
