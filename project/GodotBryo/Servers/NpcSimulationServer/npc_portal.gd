class_name NpcPortal
extends RefCounted

## A directed authored XTEL relationship. The two positions intentionally stay
## in their own raw authored coordinate spaces; this is not a rendered or
## physical navigation segment.
var source_space_form_id: int = 0
var source_position: Vector3 = Vector3.ZERO
var destination_space_form_id: int = 0
var destination_position: Vector3 = Vector3.ZERO
var source_reference: DoorReference

## Connected walkable region on each side of this door, resolved by snapping the
## authored positions. A door is the only thing joining two components, so these
## are what routing traverses; -1 until resolved (either end may sit off navmesh).
var source_component: int = -1
var destination_component: int = -1

