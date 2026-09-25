@tool
class_name PackageTarget
extends Resource

## One PACK.PTDT or PACK.PTD2 target. `target_value` is a FormID except for
## OBJECT_TYPE, where xEdit documents it as an object-type integer.
enum TargetType {
	SPECIFIC_REFERENCE = 0,
	OBJECT_ID = 1,
	OBJECT_TYPE = 2,
	LINKED_REFERENCE = 3,
}

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var target_type: TargetType = TargetType.SPECIFIC_REFERENCE
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var target_value: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var count_or_distance: int = 0
## The fourth PTDT/PTD2 word is labeled Unknown by xEdit.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var unknown: float = 0.0
