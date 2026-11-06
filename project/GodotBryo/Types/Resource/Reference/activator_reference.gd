@tool
class_name ActivatorReference
extends EsmReference

## REFR XACT activation flags.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var activation_flags: int = 0
## XEMI: the LIGH or REGN whose colour tints this placement's shapes flagged
## External_Emittance; 0 when absent. Read; used by EsmNode to tint those
## shapes' materials per placement.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var emittance_form_id: int = 0
## Runtime state with no ESM source: whether the activator is open, for
## activators with open/close animations (V19OverseerWallTerminal's items test
## the open state of the desk activator it is linked to). Set by
## SetOpenState; read by GetOpenState. Not presented yet: no activator node
## plays an open or close animation.
@export var is_open: bool = false:
	set(value):
		is_open = value
		mark_dirty()
