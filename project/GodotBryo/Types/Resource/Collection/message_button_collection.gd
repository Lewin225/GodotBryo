@tool
class_name MessageButtonCollection
extends Resource

## Not an ESM record. One MESG menu button, an ITXT and the CTDAs after it;
## added so a button's conditions stay with its text. Its position in
## MessageBase.buttons is its GetButtonPressed index.

## ITXT: the button text. Read; used by ScriptServer's ShowMessage.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var text: String = ""
## CTDA: the conditions after this button's ITXT. Read; MESG holds 259 in
## FalloutNV.esm. Used by ScriptServer's ShowMessage, which hides a button
## whose conditions fail.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "ConditionSubrecord", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var conditions: Array[ConditionSubrecord] = []
