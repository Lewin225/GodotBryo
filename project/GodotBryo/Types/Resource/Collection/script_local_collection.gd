@tool
class_name ScriptLocalCollection
extends Resource

## One embedded-event SLSD/SCVR local variable. xEdit identifies the index
## and type byte; the remaining SLSD bytes are deliberately retained raw.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var index: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var variable_type: int = 0
@export var name: String = ""
var raw_data: PackedByteArray = PackedByteArray()
