@tool
class_name LeveledItemRecord
extends EsmRecordResource

## LVLO entries stay authored; runtime selection is a separate policy.
@export var entries: Array[Dictionary] = []
