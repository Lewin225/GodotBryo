@tool
class_name TalkingActivatorBase
extends EsmBase

## TACT Model Data model path.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
## VNAM: the VTYP voice type FormID; TACT records carry no VTCK. Read; not
## used yet (dialogue voice file paths and GetIsVoiceType).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var voice_type_form_id: int = 0
## TACT SNAM sound FormID.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var sound_form_id: int = 0
## Resolved TACT SNAM sound path.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var sound_path: String = ""
