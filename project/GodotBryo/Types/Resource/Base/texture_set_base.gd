@tool
class_name TextureSetBase
extends EsmBase

## TXST (Texture Set). Named by Alternate Textures entries (AlternateTextureCollection);
## LTEX names one too, which the terrain reads natively. EsmBase holds EDID.
## Texture paths are relative to `textures\`; a missing TXnn reads as "".
##
## Not read (xEdit labels): DODT Decal Data, on 3 of 493 TXST in FalloutNV.esm.

const FLAG_NO_SPECULAR_MAP := 0x0001
const FLAG_NAMES := "No Specular Map:1"

## OBND: the object bounds' two corners (s16 x, y, z each). Present on 410 of
## 493 TXST. Read; not used.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var bounds_min: Vector3i = Vector3i.ZERO
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var bounds_max: Vector3i = Vector3i.ZERO
## TX00 (Base Image / Transparency): the diffuse. Present on 492 of 493. Read;
## not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var diffuse_path: String = ""
## TX01 (Normal Map / Specular). Present on 486. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var normal_path: String = ""
## TX02 (Environment Map Mask). Present on 117. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var environment_mask_path: String = ""
## TX03 (Glow Map). Present on 46. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var glow_path: String = ""
## TX04 (Parallax Map). Present on 11. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var parallax_path: String = ""
## TX05 (Environment Map). Present on 114. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var environment_path: String = ""
## DNAM (u16) flags. Present on 313 of 493; 15 set No Specular Map. Read; not
## used yet.
@export_custom(PROPERTY_HINT_FLAGS, FLAG_NAMES, PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
