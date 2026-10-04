@tool
class_name GlobalBase
extends EsmBase

## GLOB (Global). Named by COED's global variable and by scripts and
## conditions. EsmBase holds EDID. Every subrecord is read. The authored value
## only: scripts change globals through ScriptServer's GlobalVariables, the
## runtime store that seeds each global from its record and is saved.

const TYPE_SHORT := "s"
const TYPE_LONG := "l"
const TYPE_FLOAT := "f"

## FNAM: the type, "s" (short), "l" (long) or "f" (float). Read; not used yet
## (GlobalVariables reads the record through EsmServer.find_global_by_editor_id).
@export_custom(PROPERTY_HINT_ENUM, "s,l,f", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var global_type: String = TYPE_FLOAT
## FLTV: the authored value, a float for every type. Read; not used yet (as
## global_type).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var value: float = 0.0
