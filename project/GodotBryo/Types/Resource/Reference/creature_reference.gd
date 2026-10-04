@tool
class_name CreatureReference
extends ActorReference

## ACRE (Placed Creature): an ActorReference whose base is a CreatureBase,
## plus ownership, which xEdit gives ACRE and not ACHR.

@export_group("Ownership")
## XOWN: the owner, an NpcBase or FactionBase (10 ACRE in FalloutNV.esm).
## Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var owner_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var owner: EsmBase
## XRNK (owner faction rank). Present on no ACRE in FalloutNV.esm; not read.
@export var owner_faction_rank: int = -1
@export_group("")
