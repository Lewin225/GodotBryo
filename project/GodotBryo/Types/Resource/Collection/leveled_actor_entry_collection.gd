@tool
class_name LeveledActorEntryCollection
extends Resource

## One LVLO of an LVLN or LVLC (LeveledActorBase.entries).

## LVLO offset 0: the level the entry is chosen from (s16). Read; used by
## LeveledActorResolver.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var level: int = 0
## LVLO offset 4: the NPC_, CREA, LVLN or LVLC. Read; resolved into `actor`.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var actor_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var actor: EsmBase
## LVLO offset 8: Count (s16). Read; not used: 1 on every LVLN and LVLC entry
## in FalloutNV.esm.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var count: int = 1
