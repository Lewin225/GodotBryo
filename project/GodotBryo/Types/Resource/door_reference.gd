@tool
class_name DoorReference
extends EsmReference

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
## Whether REFR XLOC marks this door as locked.
@export var is_locked: bool = false
## Whether the REFR XLOC lock uses a leveled lock.
@export var is_leveled_lock: bool = false
## Whether REFR XACT/ONAM marks this door open by default.
@export var is_open_by_default: bool = false
## REFR XTEL no-alarm teleport flag.
@export var teleport_no_alarm: bool = false
## Whether this REFR has an XTEL teleport destination.
@export var has_teleport_destination: bool = false
## REFR XTEL destination door reference FormID.
@export var teleport_destination_refr_form_id: int = 0
## Owning cell of the REFR XTEL destination.
@export var teleport_destination_cell_form_id: int = 0
## REFR XTEL destination position.
@export var teleport_position: Vector3 = Vector3.ZERO
## REFR XTEL destination rotation.
@export var teleport_rotation: Vector3 = Vector3.ZERO
## Current runtime open state.
@export var is_open: bool = false
