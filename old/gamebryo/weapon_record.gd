@tool
class_name WeaponRecord
extends EsmRecordResource

## WEAP.DNAM animation category (the first uint32 of DNAM).
const ANIMATION_HAND_TO_HAND := 0
const ANIMATION_ONE_HANDED_MELEE := 1
const ANIMATION_TWO_HANDED_MELEE := 2
const ANIMATION_ONE_HANDED_BALLISTIC := 3
const ANIMATION_ONE_HANDED_ENERGY := 4
const ANIMATION_TWO_HANDED_BALLISTIC := 5
const ANIMATION_TWO_HANDED_AUTOMATIC := 6
const ANIMATION_TWO_HANDED_ENERGY := 7
const ANIMATION_TWO_HANDED_HANDLE := 8
const ANIMATION_TWO_HANDED_LAUNCHER := 9
const ANIMATION_GRENADE_THROW := 10
const ANIMATION_LAND_MINE := 11
const ANIMATION_MINE_DROP := 12
const ANIMATION_THROWN := 13

@export var full_name: String = ""
@export var model_path: String = ""
@export var first_person_form_id: int = 0
@export var value: int = 0
@export var health: int = 0
@export var weight: float = 0.0
@export var base_damage: int = 0
@export var clip_size: int = 0
@export var equipment_type: int = 0
@export var animation_type: int = -1
@export var animation_family: String = ""
@export var animation_flags_1: int = 0
@export var grip_animation: int = 255
@export var ammo_use: int = 0
@export var reload_animation: int = 255
@export var attack_animation: int = 255
@export var animation_flags_2: int = 0
@export var biped_model_list: BipedModelListResource

func action_clip_name(action: String) -> String:
	if animation_family.is_empty():
		return ""
	match action.to_lower():
		"equip": return animation_family + "equip.kf"
		"unequip": return animation_family + "unequip.kf"
		"idle": return animation_family + "idle.kf"
		"block": return animation_family + "blockidle.kf"
		"holster": return animation_family + "holster.kf"
		"grip": return _grip_clip_name()
		"attack": return animation_family + _attack_suffix() + ".kf"
		"reload": return animation_family + _reload_suffix() + ".kf"
		_: return ""

func _attack_suffix() -> String:
	match attack_animation:
		26: return "attackleft"
		32: return "attackright"
		38: return "attack3"
		44: return "attack4"
		50: return "attack5"
		56: return "attack6"
		62: return "attack7"
		68: return "attack8"
		74: return "attackloop"
		80: return "attackspin"
		86: return "attackspin2"
		102: return "placemine"
		108: return "placemine2"
		114: return "attackthrow"
		120: return "attackthrow2"
		126: return "attackthrow3"
		132: return "attackthrow4"
		138: return "attackthrow5"
		144: return "attack9"
		150: return "attackthrow6"
		156: return "attackthrow7"
		162: return "attackthrow8"
		255:
			if animation_family == "1gt": return "attackthrow"
			if animation_family == "1lm" or animation_family == "1md": return "placemine"
			return "attackleft"
		_: return ""

func _reload_suffix() -> String:
	if reload_animation == 255:
		return "reloada"
	var suffixes := ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "w", "x", "y", "z"]
	if reload_animation < suffixes.size():
		return "reload" + suffixes[reload_animation]
	return ""

func _grip_clip_name() -> String:
	if grip_animation >= 230 and grip_animation <= 234:
		return animation_family + "handgrip" + str(grip_animation - 229) + ".kf"
	return ""
