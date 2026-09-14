@tool
@icon("res://GodotBryo/Types/Node/movable_static.svg")
class_name EsmMovableStaticNode
extends EsmNode

## MSTT remains an individual node because its runtime transform may diverge
## from authored placement. Movement/physics behavior is a later layer.
