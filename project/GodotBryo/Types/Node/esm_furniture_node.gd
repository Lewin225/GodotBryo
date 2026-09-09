@tool
@icon("res://GodotBryo/Types/Node/furniture.svg")
class_name EsmFurnitureNode
extends EsmNode

@export_tool_button("Activate") var activate_button: Callable = activate

func build_visual(resolver: GamebryoMeshResolver) -> void:
	var furniture_ref := reference as FurnitureReference
	if furniture_ref == null or not furniture_ref.base is FurnitureBase:
		return
	build_dynamic_visual(resolver, (furniture_ref.base as FurnitureBase).model_path)
	_visual_built = true

func activate(_actor: Node = null) -> Dictionary:
	var player := get_node_or_null("AnimationPlayer") as AnimationPlayer
	if player != null:
		if player.has_animation("Use"):
			player.play("Use")
		elif player.has_animation("Activate"):
			player.play("Activate")
	return {}
