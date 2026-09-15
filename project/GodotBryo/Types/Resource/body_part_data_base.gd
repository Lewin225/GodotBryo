@tool
class_name BodyPartDataBase
extends EsmBase

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skeleton_model_path: String = ""
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var ragdoll_form_id: int = 0
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "BodyPartDataPart", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var parts: Array[BodyPartDataPart] = []
