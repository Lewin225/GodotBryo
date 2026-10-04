@tool
class_name BodyPartDataPart
extends Resource

## One BPTD body-part collection. This is authored inside a BodyPartDataBase,
## rather than being an ESM record with an independent FormID.
enum PartType {
	TORSO = 0,
	HEAD_1 = 1,
	HEAD_2 = 2,
	LEFT_ARM_1 = 3,
	LEFT_ARM_2 = 4,
	RIGHT_ARM_1 = 5,
	RIGHT_ARM_2 = 6,
	LEFT_LEG_1 = 7,
	LEFT_LEG_2 = 8,
	LEFT_LEG_3 = 9,
	RIGHT_LEG_1 = 10,
	RIGHT_LEG_2 = 11,
	RIGHT_LEG_3 = 12,
	BRAIN = 13,
	WEAPON = 14,
}

enum Flags {
	SEVERABLE = 0x01,
	IK_DATA = 0x02,
	IK_DATA_BIPED = 0x04,
	EXPLODABLE = 0x08,
	IK_DATA_IS_HEAD = 0x10,
	IK_DATA_HEADTRACKING = 0x20,
	TO_HIT_CHANCE_ABSOLUTE = 0x40,
}

## BPND stores this as int8. Variable01–Variable10 are user-defined actor
## values: the engine provides no gameplay meaning, but quests can use them as
## permanent actor data (and defining one makes it exist for every actor).
enum ActorValue {
	NONE = -1,
	AGGRESSION = 0, CONFIDENCE = 1, ENERGY = 2, RESPONSIBILITY = 3, MOOD = 4,
	STRENGTH = 5, PERCEPTION = 6, ENDURANCE = 7, CHARISMA = 8, INTELLIGENCE = 9,
	AGILITY = 10, LUCK = 11, ACTION_POINTS = 12, CARRY_WEIGHT = 13, CRITICAL_CHANCE = 14,
	HEAL_RATE = 15, HEALTH = 16, MELEE_DAMAGE = 17, DAMAGE_RESISTANCE = 18,
	POISON_RESISTANCE = 19, RADIATION_RESISTANCE = 20, SPEED_MULTIPLIER = 21,
	FATIGUE = 22, KARMA = 23, EXPERIENCE = 24, PERCEPTION_CONDITION = 25,
	ENDURANCE_CONDITION = 26, LEFT_ATTACK_CONDITION = 27, RIGHT_ATTACK_CONDITION = 28,
	LEFT_MOBILITY_CONDITION = 29, RIGHT_MOBILITY_CONDITION = 30, BRAIN_CONDITION = 31,
	BARTER = 32, BIG_GUNS = 33, ENERGY_WEAPONS = 34, EXPLOSIVES = 35, LOCKPICK = 36,
	MEDICINE = 37, MELEE_WEAPONS = 38, REPAIR = 39, SCIENCE = 40, SMALL_GUNS = 41,
	SNEAK = 42, SPEECH = 43, THROWING_UNUSED = 44, UNARMED = 45, INVENTORY_WEIGHT = 46,
	PARALYSIS = 47, INVISIBILITY = 48, CHAMELEON = 49, NIGHT_EYE = 50,
	DETECT_LIFE_RANGE = 51, FIRE_RESISTANCE = 52, WATER_BREATHING = 53,
	RADIATION_LEVEL = 54, BLOODY_MESS = 55, UNARMED_DAMAGE = 56, ASSISTANCE = 57,
	ELECTRIC_RESISTANCE = 58, FROST_RESISTANCE = 59, ENERGY_RESISTANCE = 60,
	EMP_RESISTANCE = 61, VARIABLE_01 = 62, VARIABLE_02 = 63, VARIABLE_03 = 64,
	VARIABLE_04 = 65, VARIABLE_05 = 66, VARIABLE_06 = 67, VARIABLE_07 = 68,
	VARIABLE_08 = 69, VARIABLE_09 = 70, VARIABLE_10 = 71, IGNORE_NEGATIVE_EFFECTS = 72,
}

const PART_TYPE_HINT := "Torso:0,Head 1:1,Head 2:2,Left Arm 1:3,Left Arm 2:4,Right Arm 1:5,Right Arm 2:6,Left Leg 1:7,Left Leg 2:8,Left Leg 3:9,Right Leg 1:10,Right Leg 2:11,Right Leg 3:12,Brain:13,Weapon:14"
const FLAGS_HINT := "Severable:1,IK Data:2,IK Data - Biped:4,Explodable:8,IK Data - Is Head:16,IK Data - Headtracking:32,To Hit Chance - Absolute:64"
const ACTOR_VALUE_HINT := "None:-1,Aggression:0,Confidence:1,Energy:2,Responsibility:3,Mood:4,Strength:5,Perception:6,Endurance:7,Charisma:8,Intelligence:9,Agility:10,Luck:11,Action Points:12,Carry Weight:13,Critical Chance:14,Heal Rate:15,Health:16,Melee Damage:17,Damage Resistance:18,Poison Resistance:19,Radiation Resistance:20,Speed Multiplier:21,Fatigue:22,Karma:23,Experience:24,Perception Condition:25,Endurance Condition:26,Left Attack Condition:27,Right Attack Condition:28,Left Mobility Condition:29,Right Mobility Condition:30,Brain Condition:31,Barter:32,Big Guns:33,Energy Weapons:34,Explosives:35,Lockpick:36,Medicine:37,Melee Weapons:38,Repair:39,Science:40,Small Guns:41,Sneak:42,Speech:43,Throwing (unused):44,Unarmed:45,Inventory Weight:46,Paralysis:47,Invisibility:48,Chameleon:49,Night Eye:50,Detect Life Range:51,Fire Resistance:52,Water Breathing:53,Radiation Level:54,Bloody Mess:55,Unarmed Damage:56,Assistance:57,Electric Resistance:58,Frost Resistance:59,Energy Resistance:60,EMP Resistance:61,Variable01:62,Variable02:63,Variable03:64,Variable04:65,Variable05:66,Variable06:67,Variable07:68,Variable08:69,Variable09:70,Variable10:71,Ignore Negative Effects:72"

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var part_name: String = ""
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var part_node: String = ""
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var vats_target: String = ""
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var ik_start_node: String = ""
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var damage_multiplier: float = 0.0
@export_custom(PROPERTY_HINT_FLAGS, FLAGS_HINT, PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
@export_custom(PROPERTY_HINT_ENUM, PART_TYPE_HINT, PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var part_type: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var health_percent: int = 0
@export_custom(PROPERTY_HINT_ENUM, ACTOR_VALUE_HINT, PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var actor_value: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var hit_chance: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var explosion_chance: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var explosion_debris_count: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var explosion_debris_form_id: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var explosion_form_id: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var tracking_max_angle: float = 0.0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var explosion_debris_scale: float = 0.0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var severable_debris_count: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var severable_debris_form_id: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var severable_explosion_form_id: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var severable_debris_scale: float = 0.0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var gore_translation: Vector3 = Vector3.ZERO
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var gore_rotation: Vector3 = Vector3.ZERO
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var severable_impact_dataset_form_id: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var explosion_impact_dataset_form_id: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var severable_decal_count: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var explosion_decal_count: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var limb_replacement_scale: float = 0.0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var limb_replacement_model: String = ""
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var gore_target_bone: String = ""
var texture_file_hashes := PackedByteArray()
var raw_bpnd := PackedByteArray()
