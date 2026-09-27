@tool
class_name QuestObjective
extends Resource

## One QUST objective: its QOBJ index, NNAM text and QSTA targets. Not an ESM
## record; its position in QuestBase.objectives preserves authored order, which
## is not index order. Whether it is displayed or completed is runtime state in
## the quest's QuestState.

## QOBJ: the objective index (int32). Read; unique within its quest in
## FalloutNV.esm (1045 objectives, indexes 0-200). Used by QuestServer to
## accept SetObjectiveDisplayed / SetObjectiveCompleted only for indexes the
## quest defines.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var index: int = 0
## NNAM: the objective text shown in the Pip-Boy. Read; every objective has one
## NNAM, 17 of them empty. Not used yet; the journal / Pip-Boy view would show it.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var text: String = ""
## The QSTA targets that follow this objective's NNAM, in authored order. Read;
## 892 of 1045 objectives have at least one (up to 23). Not used yet; compass
## and map markers would use them.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var targets: Array[QuestObjectiveTarget] = []
