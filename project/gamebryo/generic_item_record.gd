class_name GenericItemRecord
extends EsmRecordResource

## Generic inventory definition for item types that do not yet need a
## specialized gameplay/visual resource. The source record remains available
## through EsmRecordResource.raw_subrecords.
@export var full_name: String = ""
@export var value: int = 0
@export var weight: float = 0.0
@export var inventory_icon: String = ""
@export var message_icon: String = ""
