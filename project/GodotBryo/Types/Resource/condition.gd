@tool
class_name Condition
extends Resource

## One CTDA condition, on whichever record carries it: a dialogue response,
## package, idle, quest (quest conditions, stage log entries, objective
## targets), terminal menu item, message button, perk, effect, recipe or
## camera path. FalloutNV.esm holds 68,005 on 12 record types. Evaluated by
## ConditionEvaluator; parameter meaning depends on the function, so both
## parameters stay as their raw 32-bit words here.

## CTDA byte 0, top three bits: the comparison.
enum Comparison { EQUAL, NOT_EQUAL, GREATER, GREATER_OR_EQUAL, LESS, LESS_OR_EQUAL }
## CTDA Run On values outside IDLE records, where the field holds an
## animation group instead.
enum RunOn { SUBJECT, TARGET, REFERENCE, COMBAT_TARGET, LINKED_REFERENCE }

## CTDA byte 0 flag: this condition is OR'd with the next.
const FLAG_OR := 0x01
## CTDA byte 0 flag: the comparison value is a GLOB's current value.
const FLAG_USE_GLOBAL := 0x04

## CTDA byte 0, top three bits. Read; values 0-5 only in FalloutNV.esm (==
## 57,475, != 3,108, > 841, >= 3,365, < 2,369, <= 847; the operator order is
## recalled). Used by ConditionEvaluator.
@export_custom(PROPERTY_HINT_ENUM, "==,!=,>,>=,<,<=", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var comparison: Comparison = Comparison.EQUAL
## CTDA byte 0, low five bits. Read; FLAG_OR on 2,898, FLAG_USE_GLOBAL on 59,
## 0x10 once (meaning unknown), 0x02 (xEdit: Run On Target) and 0x08 never.
## Used by ConditionEvaluator.
@export_custom(PROPERTY_HINT_FLAGS, "Or:1,Run On Target:2,Use Global:4,Unknown 0x08:8,Unknown 0x10:16", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
## CTDA bytes 4-7 as a float: the value the function's result is compared
## with. Read; used by ConditionEvaluator unless FLAG_USE_GLOBAL is set.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var comparison_value: float = 0.0
## CTDA bytes 4-7 as a GLOB FormID, when FLAG_USE_GLOBAL is set (all 59 such
## words name a GLOB); else 0. Read; used by ConditionEvaluator.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var comparison_global_form_id: int = 0
## CTDA bytes 8-9: the condition function's index in xEdit's
## wbConditionFunctions (144 distinct in FalloutNV.esm). Read; used by
## ConditionEvaluator through ScriptConditionFunctions.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var function_index: int = 0
## CTDA bytes 12-15: the first parameter, an integer or a FormID by the
## function's parameter type. Read; used by ConditionEvaluator.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var parameter_1: int = 0
## CTDA bytes 16-19: the second parameter, as parameter_1. Read; used by
## ConditionEvaluator.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var parameter_2: int = 0
## CTDA bytes 20-23: what the function runs on (RunOn), or on IDLE records an
## animation group. Read; absent (SUBJECT) on the 125 short-form CTDAs. Used
## by ConditionEvaluator.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var run_on: int = RunOn.SUBJECT
## CTDA bytes 24-27: the reference for RunOn.REFERENCE; 0x14 is the player's
## reference, which has no ESM record (1,298 conditions). Set on 179 other
## conditions, where it is ignored. Read; used by ConditionEvaluator.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var reference_form_id: int = 0
## Not a CTDA field: whether bytes 20-23 were present. False on the 20-byte
## short form (123 in FalloutNV.esm). Set by EsmServer; used only for
## inspection.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var has_run_on: bool = false

func is_or() -> bool:
	return (flags & FLAG_OR) != 0

func uses_global() -> bool:
	return (flags & FLAG_USE_GLOBAL) != 0
