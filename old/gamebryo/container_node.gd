class_name ContainerNode
extends GamebryoVisual

const InventoryComponentScript := preload("res://gamebryo/inventory_component.gd")

## CONT. Zero fields beyond GamebryoVisual today — inventory contents/open
## state is interactive behavior, out of Phase 1's scope. See
## phases/1/architecture.md's "typed node vs. generic node" rule.
var inventory_component: Node = null

func _ready() -> void:
	_ensure_inventory_component()

func _ensure_inventory_component() -> Node:
	if inventory_component != null and is_instance_valid(inventory_component):
		return inventory_component
	inventory_component = get_node_or_null(^"InventoryComponent")
	if inventory_component == null:
		inventory_component = InventoryComponentScript.new()
		inventory_component.name = "InventoryComponent"
		add_child(inventory_component)
		if Engine.is_editor_hint() and get_tree().edited_scene_root != null:
			inventory_component.owner = get_tree().edited_scene_root
	return inventory_component

func set_authored_inventory(entries: Array) -> void:
	_ensure_inventory_component().set_authored_entries(entries)
