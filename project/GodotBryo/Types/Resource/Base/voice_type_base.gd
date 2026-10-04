@tool
class_name VoiceTypeBase
extends EsmBase

## VTYP (Voice Type). Named by NPC_ and CREA VTCK. EsmBase holds EDID. Every
## subrecord is read.

## DNAM: flags (xEdit: Allow Default Dialog, Female). Read; not used yet
## (GetIsVoiceType and the voice-file path use the record's FormID and editor
## ID).
@export_custom(PROPERTY_HINT_FLAGS, "Allow Default Dialog,Female", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
