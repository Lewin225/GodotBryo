@tool
class_name MessageBase
extends EsmBase

## DESC: the message text. Read; not used yet (MessageBox shows the native
## message dictionary's text).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var description: String = ""
## INAM: the MICN icon FormID. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var icon_form_id: int = 0
## DNAM: flags, 0x01 Message Box and 0x02 Auto Display. Read; not used yet.
@export_custom(PROPERTY_HINT_FLAGS, "Message Box:1,Auto Display:2", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
## TNAM: seconds a notification stays up; 0 when absent. Read; not used yet
## (MessageBox reads the native message dictionary's display time).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var display_time: int = 0
## ITXT and CTDA: the menu buttons in authored order. Read; used by
## ScriptServer's ShowMessage for button conditions.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "MessageButtonCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var buttons: Array[MessageButtonCollection] = []
