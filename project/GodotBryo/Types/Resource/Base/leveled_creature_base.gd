@tool
class_name LeveledCreatureBase
extends EsmBase

## LVLC (Leveled Creature). Named by CREA TPLT when a CREA takes its template
## from a leveled list. EsmBase holds EDID.
##
## Not read yet (xEdit labels): OBND Object Bounds; LVLD Chance None; LVLF Flags
## (Calculate from all levels <= player's level, Calculate for each item in
## count); Leveled List Entries (LVLO: level, CREA or LVLC, count; each may be
## followed by COED Extra Data); MODL model. Read when template resolution
## chooses a creature from a leveled list.
