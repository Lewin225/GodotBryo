@tool
class_name NpcBase
extends EsmBase
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
var race_form_id: int = 0
var hair_form_id: int = 0
var eyes_form_id: int = 0
var class_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "RaceBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var race: RaceBase
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "HairBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var hair: HairBase
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EyesBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var eyes: EyesBase
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "ClassBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var actor_class: ClassBase
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "PackageBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var packages: Array[PackageBase] = []
