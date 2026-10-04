@tool
class_name RacePartBaseResource
extends Resource

## One authored RACE head/body part descriptor. These entries are derived from
## the RACE record's marker-delimited INDX/MODL/ICON collections and have no
## independent FormID.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var index: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var part_type: String = ""
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var icon_path: String = ""
