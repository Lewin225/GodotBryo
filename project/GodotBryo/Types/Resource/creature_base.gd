@tool
class_name CreatureBase
extends EsmBase
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
@export var model_list_filenames: Array[String] = []
@export var model_list_paths: Array[String] = []
@export var animation_filenames: Array[String] = []
@export var animation_paths: Array[String] = []
@export var pnam_values: Array[int] = []
