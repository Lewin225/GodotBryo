@tool
@icon("res://GodotBryo/Types/Node/activator.svg")
class_name EsmActivatorNode
extends EsmNode

@export_tool_button("Activate") var activate_button: Callable = activate

func build_visual(resolver: GamebryoMeshResolver) -> void:
	var activator := reference as ActivatorReference
	if activator == null or not activator.base is ActivatorBase:
		return
	var base := activator.base as ActivatorBase
	build_dynamic_visual(resolver, base.model_path)
	_add_sound("ActivationSound", resolver, base.activation_sound_path)
	_add_sound("LoopingSound", resolver, base.looping_sound_path, true)
	_visual_built = true

func activate(_actor: Node = null) -> Dictionary:
	var player := get_node_or_null("AnimationPlayer") as AnimationPlayer
	if player != null and player.has_animation("Activate"):
		player.play("Activate")
	_play_sound("ActivationSound")
	return {}

func _add_sound(node_name: String, resolver: GamebryoMeshResolver, path: String, looping := false) -> void:
	if path.is_empty(): return
	var stream := resolver.load_sound(path)
	if stream == null: return
	var player := AudioStreamPlayer3D.new()
	player.name = node_name
	player.stream = stream.duplicate()
	if looping: (player.stream as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
	add_child(player)

func _play_sound(node_name: String) -> void:
	var player := get_node_or_null(node_name) as AudioStreamPlayer3D
	if player != null: player.play()
