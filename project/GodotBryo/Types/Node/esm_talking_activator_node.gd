@tool
@icon("res://GodotBryo/Types/Node/talking_activator.svg")
class_name EsmTalkingActivatorNode
extends EsmNode

@export_tool_button("Activate") var activate_button: Callable = activate

## Dialogue/voice dispatch is intentionally deferred to the script/dialogue
## systems. The node still exposes the normal activation pathway now.
func activate(_actor: Node = null) -> Dictionary:
	var player := get_nif_animation_player()
	if player != null:
		if player.has_animation("Activate"):
			player.play("Activate")
		elif player.has_animation("Use"):
			player.play("Use")
	return {}
