@tool
class_name WeaponReference
extends EsmReference

@export var condition: float = -1.0:
	set(value):
		condition = value
		mark_dirty()
@export var count: int = 1:
	set(value):
		count = value
		mark_dirty()
@export var loaded_ammo_form_id: int = 0:
	set(value):
		loaded_ammo_form_id = value
		mark_dirty()
@export var loaded_ammo_count: int = 0:
	set(value):
		loaded_ammo_count = value
		mark_dirty()
