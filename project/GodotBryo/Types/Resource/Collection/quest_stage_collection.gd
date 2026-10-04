@tool
class_name QuestStageCollection
extends Resource

## One QUST stage (INDX) and its log entries. Not an ESM record; its position
## in QuestBase.stages preserves authored order.

## INDX stage number.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var index: int = 0
## Log entries in authored order; the first whose conditions pass is used.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var log_entries: Array[QuestLogEntryCollection] = []
