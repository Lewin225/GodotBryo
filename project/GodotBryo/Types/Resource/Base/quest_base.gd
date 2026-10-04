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
## DATA flags 0x04 (Allow Repeated Conversation Topics), on 94 of 436 QUST
## records in FalloutNV.esm. Read; not used yet (NPC-to-NPC conversations use
## a topic once unless it is set).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var allows_repeated_topics: bool = false
## DATA flags 0x08 (Allow Repeated Stages), on 34 of 436 QUST records. Read;
## not used yet (without it, SetStage does nothing after a stage's first).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var allows_repeated_stages: bool = false
## DATA flags 0x10 (Default Script Processing Delay), on 282 of 436 QUST
## records: the quest script uses the engine's default delay rather than
## `script_delay`. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var uses_default_script_delay: bool = false
## DATA byte 1.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var priority: int = 0
## DATA bytes 4-7: seconds between runs of the quest script's GameMode block;
## 0 means the engine default.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var script_delay: float = 0.0
## CTDA conditions on the quest itself (before its first stage), in authored
## order. Read; not used yet.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "ConditionSubrecord", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var conditions: Array[ConditionSubrecord] = []
## Stages in authored order.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var stages: Array[QuestStageCollection] = []
## QOBJ objectives with their NNAM text and QSTA targets, in authored order
## (not index order). Read; 125 of 436 QUST records in FalloutNV.esm have
## objectives, 1045 in all. Used by QuestServer to validate objective indexes.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var objectives: Array[QuestObjectiveCollection] = []

## The stage with this index, or null.
func get_stage(index: int) -> QuestStageCollection:
	for stage in stages:
		if stage.index == index:
			return stage
	return null

## The objective with this QOBJ index, or null.
func get_objective(index: int) -> QuestObjectiveCollection:
	for objective in objectives:
		if objective.index == index:
			return objective
	return null
