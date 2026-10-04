@tool
class_name LeveledNpcBase
extends EsmBase

## LVLN (Leveled NPC). Named by NPC_ TPLT when an NPC_ takes its template from
## a leveled list. EsmBase holds EDID.
##
## Not read yet (xEdit labels): OBND Object Bounds; LVLD Chance None; LVLF Flags
## (Calculate from all levels <= player's level, Calculate for each item in
## count); Leveled List Entries (LVLO: level, NPC_ or LVLN, count; each may be
## followed by COED Extra Data); MODL model. Read when template resolution
## chooses an NPC from a leveled list.
