@tool
class_name ArmorReference
extends EsmReference

@export var condition: float = -1.0:
	set(value):
		condition = value
		mark_dirty()
@export var count: int = 1:
	set(value):
		count = value
		mark_dirty()
