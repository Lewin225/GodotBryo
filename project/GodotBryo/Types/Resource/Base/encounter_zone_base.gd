@tool
class_name EncounterZoneBase
extends EsmBase

## ECZN (Encounter Zone), 17 in FalloutNV.esm. Named by ACHR and ACRE XEZN and
## by CELL XEZN (EsmServer.encounter_zone_for_cell). EsmBase holds EDID.

## DATA Flags bit 0x01 (Never Resets).
const FLAG_NEVER_RESETS := 0x01
## DATA Flags bit 0x02 (Match PC Below Minimum Level).
const FLAG_MATCH_PC_BELOW_MINIMUM := 0x02

## DATA offset 0: Owner, an NPC_ or FACT. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var owner_form_id: int = 0
## DATA offset 4: Rank (s8). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var rank: int = 0
## DATA offset 5: Minimum Level (s8; 0 to 22 in FalloutNV.esm). Read; used by
## resolve_level().
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var minimum_level: int = 0
## DATA offset 6: Flags (Never Resets on 11). Read; Match PC Below Minimum
## Level used by resolve_level(); Never Resets not used until cells reset.
@export_custom(PROPERTY_HINT_FLAGS, "Never Resets:1,Match PC Below Minimum Level:2", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
## Runtime state with no ESM source: the zone's level, fixed by the first
## resolve_level() call; 0 until then. Used by ActorReference to choose from
## leveled lists.
@export var resolved_level: int = 0


## The zone's level, fixing it on the first call from `player_level`: the
## player's level, raised to the minimum level unless Match PC Below Minimum
## Level is set.
func resolve_level(player_level: int) -> int:
	if resolved_level > 0:
		return resolved_level
	resolved_level = player_level
	if (flags & FLAG_MATCH_PC_BELOW_MINIMUM) == 0:
		resolved_level = maxi(player_level, minimum_level)
	return resolved_level
