@tool
class_name CreatureBase
extends EsmBase
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
@export var model_list_filenames: Array[String] = []
@export var model_list_paths: Array[String] = []
@export var animation_filenames: Array[String] = []
@export var animation_paths: Array[String] = []
@export var pnam_values: Array[int] = []
## ACBS, DATA and AIDT stats.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "ActorStats", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var actor_stats: ActorStats
## VTCK: the VTYP voice type FormID, on 1,045 of 1,578 CREA records in
## FalloutNV.esm; 0 when absent. Read, from the record itself (a template's is
## not applied); not used yet (dialogue voice file paths and GetIsVoiceType).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var voice_type_form_id: int = 0
