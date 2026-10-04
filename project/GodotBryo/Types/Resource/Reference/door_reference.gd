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
@export_group("Teleport")
## Not an ESM field: whether the REFR has XTEL (the door teleports). Set.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var has_teleport: bool = false
## XTEL offset 0: the destination door, resolved on demand by
## get_teleport_destination(): placed references are world state, and doors
## that lead to each other would otherwise reference each other. Read; used by
## transitions and NpcSimulationServer's portals.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var teleport_destination_form_id: int = 0
## XTEL offsets 4-15: where an actor lands, metres, Gamebryo Z-up axes. The
## landing belongs to this door, not the destination: several doors can lead to
## one door with different landings. Read; used by DoorBase.activate().
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var teleport_position: Vector3 = Vector3.ZERO
## XTEL offsets 16-27: the landing rotation, radians. Read; used as
## teleport_position.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var teleport_rotation: Vector3 = Vector3.ZERO
## XTEL offset 28, flag 0x01: No Alarm. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var teleport_no_alarm: bool = false
@export_group("")
## Current runtime open state.
@export var is_open: bool = false

## The destination door's EsmServer instance id, or "" when this door does not
## teleport.
func get_teleport_destination_id() -> String:
	return "authored:%08X" % teleport_destination_form_id if has_teleport else ""

## The destination door, built on demand; null when this door does not
## teleport.
func get_teleport_destination() -> DoorReference:
	var server := get_esm_server()
	if server == null or not has_teleport:
		return null
	return server.get_reference(get_teleport_destination_id()) as DoorReference

## The space the landing is in: the destination door's space. The CELL follows
## from this space and teleport_position through EsmServer.cell_at().
func get_teleport_destination_space_form_id() -> int:
	var server := get_esm_server()
	if server == null or not has_teleport:
		return 0
	return server.get_space_form_id_for_reference(get_teleport_destination_id())
