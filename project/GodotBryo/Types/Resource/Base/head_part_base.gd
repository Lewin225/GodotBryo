@tool
class_name HeadPartBase
extends EsmBase

## HDPT (Head Part): brows, beards and the like. Named by NPC_ PNAM. EsmBase
## holds EDID and FULL.
##
## Not read (xEdit labels): MODT texture hashes; MODS Alternate Textures, on 26
## of 61 HDPT in FalloutNV.esm, which swap a beard or brow shape's texture set
## for a TXST (BeardFullT, BeardThinT, BeardCircleT, BeardLincolnT), so several
## HDPT share one NIF; read once TXST has a Base.

## MODL: the head part NIF. Present on 46 of 61 HDPT; the 15 BeardMix* records
## have none and are made of `extra_parts`. Read; not used yet (the humanoid
## head comes from RACE).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
## DATA (u8, bool): Playable. Read; not used yet (the race menu).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var playable: bool = false
## HNAM, repeated (xEdit "Extra Parts"): HDPT FormIDs. Two or three on each of
## the 15 BeardMix* records, none elsewhere; each names an HDPT with a MODL and
## no HNAM of its own. Read; resolved into `extra_parts`.
var extra_part_form_ids: Array[int] = []
## HNAM's HDPTs. Read; not used yet (built beside this part on the head).
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "HeadPartBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var extra_parts: Array[HeadPartBase] = []
