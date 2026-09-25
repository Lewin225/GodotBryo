@tool
@icon("res://GodotBryo/Types/Node/talking_activator.svg")
class_name EsmTalkingActivatorNode
extends EsmNode

@export_tool_button("Activate") var activate_button: Callable = on_activated.bind(null)

## Plays Activate, or Use when the model has no Activate animation.
func on_activated(_activator: EsmReference) -> void:
	var player := get_nif_animation_player()
	if player != null:
		if player.has_animation("Activate"):
			player.play("Activate")
		elif player.has_animation("Use"):
			player.play("Use")
