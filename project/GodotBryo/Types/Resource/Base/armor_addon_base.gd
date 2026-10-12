@tool
class_name ArmorAddonBase
extends EsmBase
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var male_biped_model: String = ""
## MODS: Alternate Textures for MODL. On 3 of 131 ARMA in FalloutNV.esm.
## Read; not used yet (NifServer would swap the named shapes' texture sets).
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "AlternateTextureCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var male_biped_alternate_textures: Array[AlternateTextureCollection] = []
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var female_biped_model: String = ""
## MO3S: Alternate Textures for MOD3. On 4 of 131 ARMA in FalloutNV.esm.
## Read; not used yet (NifServer would swap the named shapes' texture sets).
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "AlternateTextureCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var female_biped_alternate_textures: Array[AlternateTextureCollection] = []
## BMDT biped flags (ArmorBase.BIPED_FLAG_NAMES): the body slots the addon
## covers. Read; used by EsmActorNode to hide covered body parts and to show
## the hat hair under Hat.
@export_custom(PROPERTY_HINT_FLAGS, ArmorBase.BIPED_FLAG_NAMES, PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var biped_flags: int = 0
