@tool
class_name LeveledItemBase
extends EsmBase

## LVLD chance that this list produces no item.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var chance_none: int = 0
## LVLF: 0x01 all eligible levels, 0x02 recalculate each count, 0x04 use all.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
## LVLG Global FormID used to override Chance None when present.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var global_form_id: int = 0
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "LeveledItemEntry", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var entries: Array[LeveledItemEntry] = []

func calculate_from_all_levels() -> bool:
	return (flags & 0x01) != 0

func calculate_for_each_item_in_count() -> bool:
	return (flags & 0x02) != 0

func use_all() -> bool:
	return (flags & 0x04) != 0
