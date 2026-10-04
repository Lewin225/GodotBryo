@tool
class_name DestructionCollection
extends Resource

## DEST and its stages (fopdoc's "Destruction Subrecord Collection"). Shared:
## xEdit gives it to 19 record types plus NPC_ and CREA.

## DEST offset 0: Health (s32). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var health: int = 0
## DEST offset 5: Flags 0x01 (VATS Targetable). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var vats_targetable: bool = false
## DSTD ... DSTF, one per stage (DEST offset 4 is their count). Read; not used
## yet.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "DestructionStageCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var stages: Array[DestructionStageCollection] = []
