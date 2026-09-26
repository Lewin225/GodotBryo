@tool
class_name QuestLogEntry
extends Resource

## One log entry of a QUST stage: QSDT flags, CTDA conditions, CNAM log text
## and its result script.

const FLAG_COMPLETE_QUEST := 0x01
const FLAG_FAIL_QUEST := 0x02

## QSDT flags.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
## Number of CTDA conditions on this entry. The conditions are not decoded.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var condition_count: int = 0
## CNAM journal text.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var log_text: String = ""
## SCTX result script source, run when the stage is set; empty when none.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var script_source: String = ""
