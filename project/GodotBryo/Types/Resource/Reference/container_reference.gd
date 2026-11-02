@tool
class_name ContainerReference
extends EsmReference

## REFR XACT activation flags and current container state.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var activation_flags: int = 0
@export var is_open: bool = false:
	set(value):
		is_open = value
		mark_dirty()
## Live inventory aggregate. CNTO is used only when this is first created.
@export var contents: Inventory:
	set(value):
		_unwatch_inventory(contents)
		contents = value
		_watch_inventory(contents)
