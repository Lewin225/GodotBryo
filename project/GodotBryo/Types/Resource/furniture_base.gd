@tool
class_name FurnitureBase
extends EsmBase
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
## Placeholder SCPT FormID; resolve and attach through the script engine.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var script_form_id: int = 0
## FURN MNAM marker flags; individual marker meanings remain engine data.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var marker_flags: PackedByteArray = PackedByteArray()
