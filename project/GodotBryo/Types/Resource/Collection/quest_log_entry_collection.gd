@tool
class_name QuestLogEntryCollection
extends Resource

## One log entry of a QUST stage: QSDT flags, CTDA conditions, CNAM log text
## and its result script.

const FLAG_COMPLETE_QUEST := 0x01
const FLAG_FAIL_QUEST := 0x02

## QSDT flags.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
## CTDA conditions after this entry's QSDT, in authored order. Read; 20 of
## 969 log entries in FalloutNV.esm have conditions. Used by QuestServer, which
## runs the first entry without conditions (they are not evaluated yet).
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "ConditionSubrecord", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var conditions: Array[ConditionSubrecord] = []
## CNAM journal text.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var log_text: String = ""
## SCTX result script source, run when the stage is set; empty when none.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var script_source: String = ""
