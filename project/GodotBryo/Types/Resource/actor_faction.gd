@tool
class_name ActorFaction
extends Resource

## Not an ESM record. One NPC_ or CREA SNAM (xEdit `wbFaction`); added so a
## faction and the actor's rank in it stay together.

## SNAM offset 0: the FACT FormID. Read; used by GetInFaction and
## GetFactionRank.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var faction_form_id: int = 0
## SNAM offset 4 (signed): the rank; 0 on 14,566 of 14,625 SNAM in
## FalloutNV.esm, 1 to 3 on the rest. Read; used by GetFactionRank.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var rank: int = 0
