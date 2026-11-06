@tool
@icon("res://GodotBryo/Types/Node/movable_static.svg")
class_name EsmMovableStaticNode
extends EsmPhysicsNode

## MSTT remains an individual node because its runtime transform may diverge
## from authored placement. When its NIF carries a moving body, it rests and
## writes back as EsmPhysicsNode describes.
