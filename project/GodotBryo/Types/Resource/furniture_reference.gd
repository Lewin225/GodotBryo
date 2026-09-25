@tool
class_name FurnitureReference
extends EsmReference

## REFR XACT activation flags.
@export var activation_flags: int = 0

## Actor sitting at each active marker, in FurnitureBase.get_active_markers()
## order; null where free. Set only by ScriptServer.begin_use / end_use.
## Runtime state, not saved.
var occupants: Array[ActorReference] = []
