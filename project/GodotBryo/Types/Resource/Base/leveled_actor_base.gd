@tool
class_name LeveledActorBase
extends EsmBase

## The fields LVLN (LeveledNpcBase) and LVLC (LeveledCreatureBase) share: a
## list an NPC_ or CREA names in TPLT to take its template from one of its
## entries. EsmBase holds EDID. Read by EsmServer; LeveledActorResolver chooses
## an entry, and ActorReference.leveled_template keeps the choice.
##
## Not read: OBND (on every LVLN and LVLC); MODL (on none in FalloutNV.esm).

## LVLF bit 0x01 (Calculate from all levels <= player's level).
const FLAG_CALCULATE_FROM_ALL_LEVELS := 0x01
## LVLF bit 0x02 (Calculate for each item in count).
const FLAG_CALCULATE_FOR_EACH_ITEM := 0x02

## LVLD: Chance None. Read; used by LeveledActorResolver. 0 on every LVLN and
## LVLC in FalloutNV.esm.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var chance_none: int = 0
## LVLF: Flags. Read; 0x01 used by LeveledActorResolver. 0x02 has no effect on
## a list whose entries all have a count of 1, as every LVLN and LVLC entry in
## FalloutNV.esm does.
@export_custom(PROPERTY_HINT_FLAGS, "Calculate From All Levels:1,Calculate For Each Item:2", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
## LVLO: the entries, in record order (12 bytes each in FalloutNV.esm, no
## COED). Read; used by LeveledActorResolver.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "LeveledActorEntryCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var entries: Array[LeveledActorEntryCollection] = []


func calculate_from_all_levels() -> bool:
	return (flags & FLAG_CALCULATE_FROM_ALL_LEVELS) != 0
