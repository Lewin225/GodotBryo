@tool
class_name HeadPartBase
extends EsmBase

## HDPT (Head Part): brows, beards and the like. Named by NPC_ PNAM. EsmBase
## holds EDID and FULL.
##
## Not read (xEdit labels): MODT texture hashes.

## MODL: the head part NIF. Present on 46 of 61 HDPT; the 15 BeardMix* records
## have none and are made of `extra_parts`. Read; not used yet (the humanoid
## head comes from RACE).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
## MODS: Alternate Textures for MODL. On 26 of 61 HDPT in FalloutNV.esm.
## Read; not used yet (NifServer would swap the named shapes' texture sets).
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "AlternateTextureCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var alternate_textures: Array[AlternateTextureCollection] = []
## DATA (u8, bool): Playable. Read; not used yet (the race menu).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var playable: bool = false
## HNAM, repeated (xEdit "Extra Parts"): HDPT FormIDs. Two or three on each of
## the 15 BeardMix* records, none elsewhere; each names an HDPT with a MODL and
## no HNAM of its own. Read; resolved into `extra_parts`.
var extra_part_form_ids: Array[int] = []
## HNAM's HDPTs. Read; not used yet (built beside this part on the head).
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "HeadPartBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var extra_parts: Array[HeadPartBase] = []
