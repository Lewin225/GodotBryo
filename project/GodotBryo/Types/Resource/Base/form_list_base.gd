@tool
class_name FormListBase
extends EsmBase

## FLST (FormID List): a general list of records. Named by ARMO and WEAP BIPL
## (biped model lists), CREA LNAM (melee weapon list), scripts and conditions.
## EsmBase holds EDID. Every subrecord is read.

## LNAM, repeated: the listed records, in order, each resolved to its own typed
## Base. Declared EsmBase because one list can mix record types. Read; used by
## EsmHumanoidActor, which takes the ArmorAddonBase entries of an armor's or
## weapon's biped model list.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "EsmBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var entries: Array[EsmBase] = []
