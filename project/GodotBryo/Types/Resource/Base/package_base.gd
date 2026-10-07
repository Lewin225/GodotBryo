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

## PLDT / PLD2 location types (xEdit).
enum LocationType {
	NEAR_REFERENCE = 0,
	IN_CELL = 1,
	NEAR_CURRENT_LOCATION = 2,
	NEAR_EDITOR_LOCATION = 3,
	OBJECT_ID = 4,
	OBJECT_TYPE = 5,
	NEAR_LINKED_REFERENCE = 6,
	AT_PACKAGE_LOCATION = 7,
}
## PTDT / PTD2 target types (xEdit).
enum TargetType {
	SPECIFIC_REFERENCE = 0,
	OBJECT_ID = 1,
	OBJECT_TYPE = 2,
	LINKED_REFERENCE = 3,
}
## xEdit's FNV Object Type enum, for OBJECT_TYPE locations and targets.
enum ObjectType {
	NONE = 0, ACTIVATORS = 1, ARMOR = 2, BOOKS = 3, CLOTHING = 4, CONTAINERS = 5, DOORS = 6,
	INGREDIENTS = 7, LIGHTS = 8, MISCELLANEOUS = 9, FLORA = 10, FURNITURE = 11, WEAPONS_ANY = 12,
	AMMO = 13, NPCS = 14, CREATURES = 15, KEYS = 16, ALCHEMY = 17, FOOD = 18, ALL_COMBAT_WEARABLE = 19,
	ALL_WEARABLE = 20, WEAPONS_RANGED = 21, WEAPONS_MELEE = 22, WEAPONS_NONE = 23, ACTOR_EFFECTS_ANY = 24,
	ACTOR_EFFECTS_RANGE_TARGET = 25, ACTOR_EFFECTS_RANGE_TOUCH = 26, ACTOR_EFFECTS_RANGE_SELF = 27,
	UNKNOWN_28 = 28, ACTORS_ANY = 29,
}

## The player's placed-reference FormID (PLYR), which targets name directly.
const PLAYER_REFERENCE_FORM_ID := 0x14
## PKDT General Flags bit 0x2000, Always Run.
const GENERAL_FLAG_ALWAYS_RUN := 0x2000
## PKDT General Flags bit 0x100000, Head Tracking Off: the actor's head is
## locked looking straight ahead (GECK "Category Packages").
const GENERAL_FLAG_HEAD_TRACKING_OFF := 0x100000
## PKDD Flags bit 0x1, No Headtracking: speaker and target are not made to look
## at each other (GECK "Dialogue Package").
const DIALOGUE_FLAG_NO_HEADTRACKING := 0x1
## IDLF bits, the only two set in FalloutNV.esm (0x01 on 16 PACK, 0x04 on 14).
## Their names are FO3's GECK Idles tab, recalled, not verified.
const IDLE_COLLECTION_FLAG_RUN_IN_SEQUENCE := 0x01
const IDLE_COLLECTION_FLAG_DO_ONCE := 0x04

## Whether the package's General Flags have Always Run: an actor running it
## runs wherever it moves.
func is_always_run() -> bool:
	return (general_flags & GENERAL_FLAG_ALWAYS_RUN) != 0

## Type Specific Flags names by package type (xEdit), for the inspector.
const TYPE_SPECIFIC_FLAG_NAMES := {
	PackageType.FIND: "Allow Buying:256,Allow Killing:512,Allow Stealing:1024",
	PackageType.ESCORT: "Allow Buying:256,Allow Killing:512,Allow Stealing:1024",
	PackageType.EAT: "Allow Buying:256,Allow Killing:512,Allow Stealing:1024",
	PackageType.WANDER: "No Eating:1,No Sleeping:2,No Conversation:4,No Idle Markers:8,No Furniture:16,No Wandering:32",
	PackageType.SANDBOX: "No Eating:1,No Sleeping:2,No Conversation:4,No Idle Markers:8,No Furniture:16,No Wandering:32",
	PackageType.USE_ITEM_AT: "Sit Down:4,Allow Buying:256,Allow Killing:512,Allow Stealing:1024",
	PackageType.AMBUSH: "Hide While Ambushing:1",
	PackageType.GUARD: "Remain Near Reference to Guard:8",
}

@export_group("General")
## PKDT offset 0: General Flags (xEdit FNV names; bits 0x800, 0x4000, 0x8000
## and 0x10000 have none). Read; not used yet.
@export_custom(PROPERTY_HINT_FLAGS, "Offers Services:1,Must Reach Location:2,Must Complete:4,Lock Doors At Package Start:8,Lock Doors At Package End:16,Lock Doors At Location:32,Unlock Doors At Package Start:64,Unlock Doors At Package End:128,Unlock Doors At Location:256,Continue If Player Near:512,Once Per Day:1024,Skip Fallout Behavior:4096,Always Run:8192,Always Sneak:131072,Allow Swimming:262144,Allow Falls:524288,Head Tracking Off:1048576,Weapons Unequipped:2097152,Defensive Combat:4194304,Weapon Drawn:8388608,No Idle Animations:16777216,Pretend In Combat:33554432,Continue During Combat:67108864,No Combat Alert:134217728,No Warn Or Attack Behavior:268435456", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var general_flags: int = 0
## PKDT offset 4: Type. Read; used by the package census.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var package_type: PackageType = PackageType.FIND
## PKDT offset 6: Fallout Behavior Flags; 0 in the old 8-byte PKDT (13
## records). Read; not used yet.
@export_custom(PROPERTY_HINT_FLAGS, "Hellos To Player:1,Random Conversations:2,Observe Combat Behavior:4,Unknown 4:8,Reaction To Player Actions:16,Friendly Fire Comments:32,Aggro Radius Behavior:64,Allow Idle Chatter:128,Avoid Radiation:256", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var fallout_behavior_flags: int = 0
## PKDT offset 8: Type Specific Flags, named by package type; 0 in the old
## 8-byte PKDT. Read; not used yet.
@export_custom(PROPERTY_HINT_FLAGS, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var type_specific_flags: int = 0

@export_group("Location 1")
## Not an ESM field: whether the record has PLDT. Set.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var has_location_1: bool = false
## PLDT offset 0: Type. Read; used by the package census.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var location_1_type: LocationType = LocationType.NEAR_REFERENCE
## PLDT offset 4 when it names a record: the placed reference (Near reference;
## resolved on demand by get_location_reference(1), as placed references are
## world state), the CELL (In cell) or the base (Object ID). 0 otherwise. Read.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var location_1_form_id: int = 0
## PLDT offset 4's base, for Object ID. Read; not used yet.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var location_1_object: EsmBase
## PLDT offset 4 for Object Type. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var location_1_object_type: ObjectType = ObjectType.NONE
## PLDT offset 8: Radius. Read; used by the package census.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var location_1_radius: int = 0

@export_group("Location 2")
## Not an ESM field: whether the record has PLD2. Set.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var has_location_2: bool = false
## PLD2, laid out as PLDT (see Location 1). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var location_2_type: LocationType = LocationType.NEAR_REFERENCE
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var location_2_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var location_2_object: EsmBase
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var location_2_object_type: ObjectType = ObjectType.NONE
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var location_2_radius: int = 0

@export_group("Schedule")
## PSDT (on all 4,163 PACK): Month, Day Of Week, Date, Time (-1 is Any) and
## Duration (hours). Read; used by the package census.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var schedule_month: int = -1
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var schedule_day_of_week: int = -1
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var schedule_date: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var schedule_time: int = -1
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var schedule_duration_hours: int = 0

@export_group("Target 1")
## Not an ESM field: whether the record has PTDT. Set.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var has_target_1: bool = false
## PTDT offset 0: Type. Read; used by the package census.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var target_1_type: TargetType = TargetType.SPECIFIC_REFERENCE
## PTDT offset 4 when it names a record: the placed reference (Specific
## reference; resolved on demand by get_target_reference(1)) or the base
## (Object ID). 0 otherwise. Read.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var target_1_form_id: int = 0
## PTDT offset 4's base, for Object ID. Read; not used yet.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var target_1_object: EsmBase
## PTDT offset 4 for Object Type. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var target_1_object_type: ObjectType = ObjectType.NONE
## PTDT offset 8: Count / Distance. Read; used by the package census.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var target_1_count_or_distance: int = 0
## PTDT offset 12 (xEdit: Unknown, float). Read; not used.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var target_1_unknown: float = 0.0

@export_group("Target 2")
## Not an ESM field: whether the record has PTD2. Set.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var has_target_2: bool = false
## PTD2, laid out as PTDT (see Target 1). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var target_2_type: TargetType = TargetType.SPECIFIC_REFERENCE
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var target_2_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var target_2_object: EsmBase
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var target_2_object_type: ObjectType = ObjectType.NONE
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var target_2_count_or_distance: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var target_2_unknown: float = 0.0

@export_group("Conditions")
## CTDA conditions choosing whether the package runs, in authored order.
## Read; 2992 on 1814 PACK records in FalloutNV.esm. Not used yet (package
## selection is not implemented).
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "ConditionSubrecord", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var conditions: Array[ConditionSubrecord] = []

@export_group("Idle Animations")
## IDLA: the idles the package plays while it runs (Doc's VCG01 Travel
## packages list NPCSmokingIdle). Read; not used yet (Plans/Actors/stage_f.md
## step 4).
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "IdleBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var idle_animations: Array[IdleBase] = []
## IDLF: the idle collection's flags, a byte (bit names inferred, see the
## constants). Read; used by ScriptServer's ActorIdles to pick in order (Run In
## Sequence) and to stop after one pass (Do Once).
@export_custom(PROPERTY_HINT_FLAGS, "Run In Sequence:1,Do Once:4", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var idle_collection_flags: int = 0
## IDLC: the number of idles in IDLA; equal to IDLA's count on all 242 PACK
## with a collection (a byte, a u32 on 2). Read; not used (idle_animations is
## the list).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var idle_count: int = 0
## IDLT: a float, 0 on 138 of 242 collections, else 0.2 to 30; read as seconds
## between the collection's idles (inferred). Read; used by ActorIdles, with
## fAIIdleWaitTime when 0.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var idle_timer: float = 0.0

@export_group("Type Specific")
## CNAM: the combat style. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var combat_style_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "CombatStyleBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var combat_style: CombatStyleBase
## PKED: Eat Marker present. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var has_eat_marker: bool = false
## PKE2: Escort Distance. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var escort_distance: int = 0
## PKFD: Follow - Start Location - Trigger Radius. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var follow_start_location_trigger_radius: float = 0.0
## PKPT: Patrol Flags, Repeatable. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var patrol_repeatable: bool = true
## PUID: Use Item Marker present. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var has_use_item_marker: bool = false
## PKAM: Ambush Marker present. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var has_ambush_marker: bool = false

@export_group("Use Weapon")
## Not an ESM field: whether the record has PKW3. Set.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var has_use_weapon_data: bool = false
## PKW3 offset 0: Flags. Read; not used yet.
@export_custom(PROPERTY_HINT_FLAGS, "Always Hit:1,Do No Damage:256,Crouch To Reload:65536,Hold Fire When Blocked:16777216", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var use_weapon_flags: int = 0
## PKW3 offsets 4-19: Fire Rate, Fire Count, Number of Bursts, Shoots Per
## Volleys min / max, Pause Between Volleys min / max. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var use_weapon_fire_rate: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var use_weapon_fire_count: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var use_weapon_burst_count: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var use_weapon_shots_per_volley_min: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var use_weapon_shots_per_volley_max: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var use_weapon_pause_between_volleys_min: float = 0.0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var use_weapon_pause_between_volleys_max: float = 0.0

@export_group("Dialogue")
## Not an ESM field: whether the record has PKDD. Set.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var has_dialogue_data: bool = false
## PKDD offset 0: FOV. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var dialogue_field_of_view: float = 0.0
## PKDD offset 4: the topic; 0 for GREETING. Read; used by the package census.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var dialogue_topic_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "DialogueTopicBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var dialogue_topic: DialogueTopicBase
## PKDD offset 8: Flags. Read; not used yet.
@export_custom(PROPERTY_HINT_FLAGS, "No Headtracking:1,Don't Control Target Movement:256", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var dialogue_flags: int = 0
## PKDD offset 16: Dialogue Type (Conversation, Say To). Read; used by the
## package census.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var dialogue_type: int = 0
## PKDD offset 20 (xEdit: Unknown). Read; not used.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var dialogue_unknown: int = 0

@export_group("Events")
## POBA and the subrecords after it: On Begin. Read; used by PackageRunner when
## the package becomes the actor's active package.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "PackageEventCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var on_begin: PackageEventCollection
## POEA and the subrecords after it: On End. Read; used by PackageRunner when
## the package is done (a Travel package arrives, a Dialogue package's
## conversation or line starts).
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "PackageEventCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var on_end: PackageEventCollection
## POCA and the subrecords after it: On Change. Read; used by PackageRunner
## when AddScriptPackage adds the package already active (VCG01 stage 7's
## comment), and, inferred from the name, when another package replaces it
## before it is done (Plans/Actors/stage_f.md).
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "PackageEventCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var on_change: PackageEventCollection
@export_group("")

func _validate_property(property: Dictionary) -> void:
	if property.name == "type_specific_flags":
		property.hint_string = TYPE_SPECIFIC_FLAG_NAMES.get(package_type, "")

## The placed reference location `index` (1 or 2) is near, for a Near
## reference location; null otherwise. Built on demand: placed references are
## world state, not record data.
func get_location_reference(index: int) -> EsmReference:
	var type := location_1_type if index == 1 else location_2_type
	var present := has_location_1 if index == 1 else has_location_2
	var form_id := location_1_form_id if index == 1 else location_2_form_id
	if not present or type != LocationType.NEAR_REFERENCE or form_id == 0:
		return null
	var server := EsmReference.get_esm_server()
	return server.get_reference("authored:%08X" % form_id) if server != null else null

## The placed reference target `index` (1 or 2) names, for a Specific
## reference target; null otherwise. Built on demand, as get_location_reference.
func get_target_reference(index: int) -> EsmReference:
	var type := target_1_type if index == 1 else target_2_type
	var present := has_target_1 if index == 1 else has_target_2
	var form_id := target_1_form_id if index == 1 else target_2_form_id
	if not present or type != TargetType.SPECIFIC_REFERENCE or form_id == 0:
		return null
	var server := EsmReference.get_esm_server()
	if server == null:
		return null
	if form_id == PLAYER_REFERENCE_FORM_ID:
		return server.get_player_reference()
	return server.get_reference("authored:%08X" % form_id)
