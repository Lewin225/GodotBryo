@tool
class_name QuestBase
extends EsmBase

## QUST record: flags, priority, script delay and stages. Runtime state (stage
## reached, variables, running) is the quest's QuestState in QuestServer.

## QUST DATA byte 0.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
## DATA flags bit 0: the quest runs from the start of a new game.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var starts_enabled: bool = false
## DATA byte 1.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var priority: int = 0
## DATA bytes 4-7: seconds between runs of the quest script's GameMode block;
## 0 means the engine default.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var script_delay: float = 0.0
## Stages in authored order.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var stages: Array[QuestStage] = []

## The stage with this index, or null.
func get_stage(index: int) -> QuestStage:
	for stage in stages:
		if stage.index == index:
			return stage
	return null
