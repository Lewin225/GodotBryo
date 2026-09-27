@tool
class_name QuestObjectiveTarget
extends Resource

## One target of a QUST objective: a QSTA subrecord and the CTDA conditions
## that follow it. Not an ESM record; its position in QuestObjective.targets
## preserves authored order.

## QSTA flag 0x01 (xEdit: Compass Marker Ignores Locks).
const FLAG_COMPASS_MARKER_IGNORES_LOCKS := 0x01

## QSTA bytes 0-3: the FormID of the placed reference the objective points at.
## Read; in FalloutNV.esm every one is a REFR (509), ACHR (787) or ACRE (173).
## Not used yet; compass and map markers would resolve it through EsmServer.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var reference_form_id: int = 0
## QSTA byte 4: flags. Read, the whole byte. In FalloutNV.esm 1363 are 0x00,
## 105 are 0x01 and one (vMojaveGhost objective 20) is 0xE4, outside xEdit's
## one defined flag. QSTA bytes 5-7 are nonzero on almost every target and are
## not read. Not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
## Number of CTDA conditions after this QSTA, before the next QSTA or QOBJ.
## Read as a count; the conditions are not decoded or evaluated. 772 of 1469
## targets have conditions. Not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var condition_count: int = 0
