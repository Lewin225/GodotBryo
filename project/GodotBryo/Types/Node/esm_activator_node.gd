@tool
@icon("res://GodotBryo/Types/Node/activator.svg")
class_name EsmActivatorNode
extends EsmNode

@export_tool_button("Activate") var activate_button: Callable = on_activated.bind(null)

## Plays the model's Activate animation.
func on_activated(_activator: EsmReference) -> void:
	var player := get_nif_animation_player()
	if player != null and player.has_animation("Activate"):
		player.play("Activate")
