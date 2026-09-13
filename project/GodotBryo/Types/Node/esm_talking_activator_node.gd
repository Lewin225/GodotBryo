@tool
@icon("res://GodotBryo/Types/Node/talking_activator.svg")
class_name EsmTalkingActivatorNode
extends EsmNode

@export_tool_button("Activate") var activate_button: Callable = activate

func build_visual(resolver: GamebryoMeshResolver) -> void:
	var talking_ref := reference as TalkingActivatorReference
	if talking_ref == null or not talking_ref.base is TalkingActivatorBase:
		return
	var base := talking_ref.base as TalkingActivatorBase
	build_dynamic_visual(resolver, base.model_path)
	_add_sound(resolver, base.sound_path)
	_visual_built = true

## Dialogue/voice dispatch is intentionally deferred to the script/dialogue
## systems. The node still exposes the normal activation pathway now.
func activate(_actor: Node = null) -> Dictionary:
	var player := get_node_or_null("AnimationPlayer") as AnimationPlayer
	if player != null:
		if player.has_animation("Activate"):
			player.play("Activate")
		elif player.has_animation("Use"):
			player.play("Use")
	var sound := get_node_or_null("ActivationSound") as AudioStreamPlayer3D
	if sound != null:
		sound.play()
	return {}

func _add_sound(resolver: GamebryoMeshResolver, path: String) -> void:
	if path.is_empty():
		return
	var stream := resolver.load_sound(path)
	if stream == null:
		return
	var player := AudioStreamPlayer3D.new()
	player.name = "ActivationSound"
	player.stream = stream.duplicate()
	add_child(player)
