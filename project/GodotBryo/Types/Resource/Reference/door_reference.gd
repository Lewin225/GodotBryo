@tool
class_name DoorReference
extends EsmReference

## XEMI: the LIGH or REGN whose colour tints this placement's shapes flagged
## External_Emittance; 0 when absent. Read; used by EsmNode to tint those
## shapes' materials per placement.
@export var emittance_form_id: int = 0

## REFR XLOC lock level.
@export var lock_level: int = 0
## REFR XLOC key FormID.
@export var lock_key_form_id: int = 0
## Resolved REFR XLOC key record.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "KeyBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var lock_key: KeyBase
## Raw REFR XLOC lock flags.
@export var lock_flags: int = 0
## Raw REFR XACT activation flags.
@export var activation_flags: int = 0
## Current lock state. A door with XLOC starts locked at any level; level 0
## is Very Easy, not unlocked.
@export var is_locked: bool = false
## Whether the REFR XLOC lock uses a leveled lock.
@export var is_leveled_lock: bool = false
## Whether REFR XACT/ONAM marks this door open by default.
@export var is_open_by_default: bool = false
## REFR XTEL, or null when this door does not teleport.
@export var teleport: DoorTeleportLink
## Current runtime open state.
@export var is_open: bool = false
