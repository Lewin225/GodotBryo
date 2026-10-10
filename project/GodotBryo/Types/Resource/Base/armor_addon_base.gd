@tool
class_name ArmorAddonBase
extends EsmBase
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var male_biped_model: String = ""
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var female_biped_model: String = ""
## BMDT biped flags (ArmorBase.BIPED_FLAG_NAMES): the body slots the addon
## covers. Read; used by EsmActorNode to hide covered body parts and to show
## the hat hair under Hat.
@export_custom(PROPERTY_HINT_FLAGS, ArmorBase.BIPED_FLAG_NAMES, PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var biped_flags: int = 0
