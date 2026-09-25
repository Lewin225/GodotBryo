@tool
@icon("res://GodotBryo/Types/Node/container.svg")
class_name EsmContainerNode
extends EsmNode

@export_tool_button("Activate") var activate_button: Callable = on_activated.bind(null)
var inventory: Inventory

func _on_reference_ready() -> void:
	var container_ref := reference as ContainerReference
	if container_ref == null or not container_ref.base is ContainerBase:
		return
	if container_ref.contents == null:
		container_ref.contents = Inventory.new()
	inventory = container_ref.contents

## Plays the container's Open animation.
func on_activated(_activator: EsmReference) -> void:
	var player := get_nif_animation_player()
	if player != null and player.has_animation("Open"):
		player.play("Open")
