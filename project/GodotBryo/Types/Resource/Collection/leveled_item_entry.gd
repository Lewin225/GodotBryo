@tool
class_name LeveledItemEntry
extends Resource

## GodotBryo convenience resource for one LVLI entry. This is not an ESM
## record; the authored entry is LVLO plus optional following COED data.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var level: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var item_form_id: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var count: int = 1
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var item_base: EsmBase
## COED owner FormID, when authored.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var owner_form_id: int = 0
## COED health percentage, when authored; -1 means unspecified.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var health_percent: float = -1.0
## Preserved COED bytes for fields not yet interpreted.
var raw_extra_data: PackedByteArray = PackedByteArray()
