@tool
@icon("res://GodotBryo/Types/Node/furniture.svg")
class_name EsmFurnitureNode
extends EsmNode

@export_tool_button("Activate") var activate_button: Callable = on_activated.bind(null)

## Plays Use, or Activate when the model has no Use animation.
func on_activated(_activator: EsmReference) -> void:
	var player := get_nif_animation_player()
	if player != null:
		if player.has_animation("Use"):
			player.play("Use")
		elif player.has_animation("Activate"):
			player.play("Activate")
