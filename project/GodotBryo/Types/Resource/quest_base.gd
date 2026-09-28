@tool
class_name QuestBase
extends EsmBase

## QUST record: flags, priority, script delay, stages and objectives. Runtime
## state (stage reached, variables, running, objectives displayed and
## completed) is the quest's QuestState in QuestServer.

## QUST DATA byte 0.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
## DATA flags bit 0: the quest runs from the start of a new game.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var starts_enabled: bool = false
## DATA byte 1.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var priority: int = 0
## DATA bytes 4-7: seconds between runs of the quest script's GameMode block;
## 0 means the engine default.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var script_delay: float = 0.0
## CTDA conditions on the quest itself (before its first stage), in authored
## order. Read; not used yet.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "Condition", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var conditions: Array[Condition] = []
## Stages in authored order.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var stages: Array[QuestStage] = []
## QOBJ objectives with their NNAM text and QSTA targets, in authored order
## (not index order). Read; 125 of 436 QUST records in FalloutNV.esm have
## objectives, 1045 in all. Used by QuestServer to validate objective indexes.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var objectives: Array[QuestObjective] = []

## The stage with this index, or null.
func get_stage(index: int) -> QuestStage:
	for stage in stages:
		if stage.index == index:
			return stage
	return null

## The objective with this QOBJ index, or null.
func get_objective(index: int) -> QuestObjective:
	for objective in objectives:
		if objective.index == index:
			return objective
	return null
