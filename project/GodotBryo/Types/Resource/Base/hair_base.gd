@tool
class_name HairBase
extends EsmBase

## HAIR (Hair). Named by NPC_ HNAM and RACE HNAM / DNAM. EsmBase holds EDID and
## FULL.
##
## Not read (xEdit labels): MODT texture hashes.

const FLAG_PLAYABLE := 0x01
const FLAG_NOT_MALE := 0x02
const FLAG_NOT_FEMALE := 0x04
const FLAG_FIXED := 0x08
const FLAG_NAMES := "Playable:1,Not Male:2,Not Female:4,Fixed:8"

## MODL: the hair NIF, holding a NoHat and a Hat mesh. Read; used by
## NpcBase.get_model_parts, which EsmActorNode loads.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
## ICON (xEdit "Texture"): the hair's diffuse texture, relative to
## `textures\`. Present on all 67 HAIR in FalloutNV.esm. Several HAIR share one
## NIF and differ only by it (HairBase, HairCombOver, HairBalding and
## HairAfricanAmericanBase all use HairBase.NIF). Read; not used yet (the hair
## renders with its NIF's own texture).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var texture_path: String = ""
## DATA (u8) flags. Read; not used yet (the race menu's hair list).
@export_custom(PROPERTY_HINT_FLAGS, FLAG_NAMES, PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
