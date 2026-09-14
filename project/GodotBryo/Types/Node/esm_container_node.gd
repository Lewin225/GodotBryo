@tool
@icon("res://GodotBryo/Types/Node/container.svg")
class_name EsmContainerNode
extends EsmNode

@export_tool_button("Activate") var activate_button: Callable = activate
var inventory: Inventory

func _on_reference_ready() -> void:
	var container_ref := reference as ContainerReference
	if container_ref == null or not container_ref.base is ContainerBase:
		return
	if container_ref.contents == null:
		container_ref.contents = Inventory.new()
	inventory = container_ref.contents

func activate(_actor: Node = null) -> Dictionary:
	var container_ref := reference as ContainerReference
	if container_ref == null: return {}
	var opening := not container_ref.is_open
	var player := get_nif_animation_player()
	var animation_name := "Open" if opening else "Close"
	if player != null and player.has_animation(animation_name): player.play(animation_name)
	container_ref.is_open = opening
	return {}
