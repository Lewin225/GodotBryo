@tool
@icon("res://GodotBryo/Types/Node/item.svg")
class_name EsmItemNode
extends EsmPhysicsNode

## A placed item (MISC, ALCH, AMMO, KEYM, WEAP, ARMO, BOOK, CCRD, CMNY). Its body,
## when the NIF has a moving one, rests and writes back as EsmPhysicsNode
## describes. Picking an item up (ActorReference.pick_up()) wakes the bodies
## resting against it first (wake_neighbours()), so a stack does not hang in the
## air when its bottom item goes.
