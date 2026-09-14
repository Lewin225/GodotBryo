@tool
@icon("res://GodotBryo/Types/Node/activator.svg")
class_name EsmActivatorNode
extends EsmNode

@export_tool_button("Activate") var activate_button: Callable = activate

func activate(_actor: Node = null) -> Dictionary:
	var player := get_nif_animation_player()
	if player != null and player.has_animation("Activate"):
		player.play("Activate")
	return {}
