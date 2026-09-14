@tool
class_name EsmReference
extends Resource

## Runtime-resolved Base resource. It is visible for inspection but deliberately
## excluded from scene/resource storage; base_form_id is the persisted identity.
## Resolved base record for this placed REFR.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var base: EsmBase
## REFR NAME base record FormID; persisted identity for the link.
@export var base_form_id: int = 0
## Stable authored or runtime instance identifier.
@export var instance_id: String = ""
## REFR DATA position in engine coordinates.
@export var position: Vector3 = Vector3.ZERO
## REFR DATA rotation in engine coordinates.
@export var rotation: Vector3 = Vector3.ZERO
## REFR XSCL scale value.
@export var scale: float = 1.0
## Raw REFR "Visible When Distant" flag. It is authored placement data, not a
## request to load the companion model: WorldStreamer owns that spatial policy.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var visible_when_distant: bool = false
## Raw presence of the persistent skyline stand-in subrecords XSRF/XSRD. Their
## byte meaning is still undocumented; the confirmed observation is enough to
## select the separate begin-only visibility policy in EsmNode.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var has_xsrf_or_xsrd: bool = false
## Cell currently containing this reference.
@export var current_cell_form_id: int = 0
