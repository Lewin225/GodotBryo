@tool
@icon("res://GodotBryo/Types/Node/furniture.svg")
class_name EsmFurnitureNode
extends EsmNode

@export_tool_button("Activate") var activate_button: Callable = activate

func activate(_actor: Node = null) -> Dictionary:
	var player := get_nif_animation_player()
	if player != null:
		if player.has_animation("Use"):
			player.play("Use")
		elif player.has_animation("Activate"):
			player.play("Activate")
	return {}
