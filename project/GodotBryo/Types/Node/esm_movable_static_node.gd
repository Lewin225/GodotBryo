@tool
@icon("res://GodotBryo/Types/Node/movable_static.svg")
class_name EsmMovableStaticNode
extends EsmNode

## MSTT remains an individual node because its runtime transform may diverge
## from authored placement. Movement/physics behavior is a later layer.
func build_visual(resolver: GamebryoMeshResolver) -> void:
	var movable_ref := reference as MovableStaticReference
	if movable_ref == null or not movable_ref.base is MovableStaticBase:
		return
	build_dynamic_visual(resolver, (movable_ref.base as MovableStaticBase).model_path)
	_visual_built = true
