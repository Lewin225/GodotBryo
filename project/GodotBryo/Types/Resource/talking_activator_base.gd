@tool
class_name TalkingActivatorBase
extends EsmBase

## TACT Model Data model path.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
## Placeholder SCPT FormID; resolve and attach through the script engine.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var script_form_id: int = 0
## TACT VNAM Voice Type FormID.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var voice_type_form_id: int = 0
## TACT SNAM sound FormID.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var sound_form_id: int = 0
## Resolved TACT SNAM sound path.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var sound_path: String = ""
