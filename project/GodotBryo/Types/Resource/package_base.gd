@tool
class_name PackageBase
extends EsmBase

## Field layout follows `enginedocs/xEdit/Core/wbDefinitionsFNV.pas`; package
## selection semantics are documented in the local GECK package pages. This is
## authored data only: selection/evaluation belongs to the future AI runtime.
## Fallout New Vegas PACK.PKDT type values, from xEdit's FNV definition.
enum PackageType {
	FIND = 0,
	FOLLOW = 1,
	ESCORT = 2,
	EAT = 3,
	SLEEP = 4,
	WANDER = 5,
	TRAVEL = 6,
	ACCOMPANY = 7,
	USE_ITEM_AT = 8,
	AMBUSH = 9,
	FLEE_NOT_COMBAT = 10,
	CAST_MAGIC = 11,
	SANDBOX = 12,
	PATROL = 13,
	GUARD = 14,
	DIALOGUE = 15,
	USE_WEAPON = 16,
}

## PACK.PKDT's four words. The old 8-byte form in 13 shipped records has no
## Fallout/type-specific flag words, which are therefore zero for those forms.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var general_flags_raw: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "PackageGeneralFlags", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var general_flags: PackageGeneralFlags
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var package_type: PackageType = PackageType.FIND
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var fallout_behavior_flags_raw: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "PackageFalloutBehaviorFlags", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var fallout_behavior_flags: PackageFalloutBehaviorFlags
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var type_specific_flags_raw: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "PackageTypeSpecificFlags", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var type_specific_flags: PackageTypeSpecificFlags

@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "PackageLocation", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var location_1: PackageLocation
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "PackageLocation", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var location_2: PackageLocation
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "PackageSchedule", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var schedule: PackageSchedule
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "PackageTarget", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var target_1: PackageTarget
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "PackageTarget", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var target_2: PackageTarget
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "PackageCondition", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var conditions: Array[PackageCondition] = []

## PACK's Idle Animation block. The non-FormID IDLC/IDLF/IDLT words retain
## their subrecord names until their behavior is independently verified.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "int", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var idle_animation_form_ids: Array[int] = []
var idle_collection_chance_raw: PackedByteArray = PackedByteArray()
var idle_collection_flags_raw: PackedByteArray = PackedByteArray()
var idle_collection_timer_raw: PackedByteArray = PackedByteArray()

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var combat_style_form_id: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var has_eat_marker: bool = false
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var escort_distance: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var follow_start_location_trigger_radius: float = 0.0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var patrol_repeatable: bool = true
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "PackageUseWeaponData", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var use_weapon_data: PackageUseWeaponData
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var has_use_item_marker: bool = false
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var has_ambush_marker: bool = false
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "PackageDialogueData", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var dialogue_data: PackageDialogueData

@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "PackageEvent", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var on_begin: PackageEvent
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "PackageEvent", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var on_end: PackageEvent
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "PackageEvent", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var on_change: PackageEvent
