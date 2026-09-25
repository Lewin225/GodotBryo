@tool
class_name DoorTeleportLink
extends Resource

## One REFR XTEL: the door this door leads to, and where an actor lands when
## it goes through. The landing transform belongs to this link, not to the
## destination door: several doors can lead to one door with different
## landings.

## XTEL destination REFR, as an EsmServer instance id ("authored:%08X").
@export var destination_id: String = ""
## XTEL landing position: metres, Gamebryo Z-up axes.
@export var position: Vector3 = Vector3.ZERO
## XTEL landing rotation, radians.
@export var rotation: Vector3 = Vector3.ZERO
## XTEL flags bit 0.
@export var no_alarm: bool = false

## The destination door. Resolved through EsmServer on every read and never
## stored, so two doors that lead to each other do not reference each other.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "DoorReference", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY)
var destination: DoorReference:
	get:
		var server := EsmReference.get_esm_server()
		if server == null or destination_id.is_empty():
			return null
		return server.get_reference(destination_id) as DoorReference

## Space the landing is in: the destination door's space. The CELL follows
## from this space and `position` through EsmServer.cell_at().
func get_destination_space_form_id() -> int:
	var server := EsmReference.get_esm_server()
	if server == null or destination_id.is_empty():
		return 0
	return server.get_space_form_id_for_reference(destination_id)
