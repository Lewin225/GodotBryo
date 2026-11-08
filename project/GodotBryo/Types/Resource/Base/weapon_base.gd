@tool
class_name WeaponBase
extends EsmBase

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
## MODS: Alternate Textures for MODL. On 1 of 261 WEAP in FalloutNV.esm.
## Read; not used yet (NifServer would swap the named shapes' texture sets).
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "AlternateTextureCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var alternate_textures: Array[AlternateTextureCollection] = []
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var first_person_form_id: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var value: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var health: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var weight: float = 0.0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var base_damage: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var clip_size: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var equipment_type: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var animation_type: int = -1
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var biped_model_list_form_id: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var inventory_icon: String = ""
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var message_icon: String = ""
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var animation_family: String = ""
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var attack_animation: int = 255
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var reload_animation: int = 255
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var grip_animation: int = 255
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "FormListBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var biped_model_list: Resource

## The third-person clip library: the weapon's parts follow its `_male` clips.
const CLIP_FOLDER := "meshes\\characters\\_male\\"
## DNAM Attack Animation values (xEdit's enum) to the clip name after the
## family: `1hp` + `attackleft` is 1hpattackleft.kf.
const ATTACK_CLIPS := {
	26: "attackleft", 32: "attackright", 38: "attack3", 44: "attack4", 50: "attack5",
	56: "attack6", 62: "attack7", 68: "attack8", 74: "attackloop", 80: "attackspin",
	86: "attackspin2", 102: "placemine", 108: "placemine2", 114: "attackthrow",
	120: "attackthrow2", 126: "attackthrow3", 132: "attackthrow4", 138: "attackthrow5",
	144: "attack9", 150: "attackthrow6", 156: "attackthrow7", 162: "attackthrow8",
}
## DNAM Attack Animation 255: xEdit's DEFAULT. On 4 guns in FalloutNV.esm.
const ATTACK_DEFAULT := 255
## The reload ids whose clip letter is not their place in the alphabet.
const RELOAD_LETTERS := {20: "x", 21: "y", 22: "z"}
## Reload ids 0 to this take the letter at their place: 0 is a, 16 is q.
const LAST_ALPHABET_RELOAD := 16


## The attack clip's path, "" when the weapon has no family.
func attack_clip_path() -> String:
	if animation_family.is_empty():
		return ""
	var clip := String(ATTACK_CLIPS.get(attack_animation, ""))
	if attack_animation == ATTACK_DEFAULT:
		# ASSUMPTION: DEFAULT plays attackleft. Nothing in the data says which
		# clip DEFAULT stands for; attackleft is the lowest named value.
		clip = "attackleft"
	if clip.is_empty():
		return ""
	return CLIP_FOLDER + animation_family + clip + ".kf"


## The reload clip's path, "" when the weapon's reload id has no clip (17 to
## 19, DEFAULT) or it has no family.
func reload_clip_path() -> String:
	var letter := _reload_letter()
	if letter.is_empty():
		return ""
	return CLIP_FOLDER + animation_family + "reload" + letter + ".kf"


## The jam clip's path: the reload's letter, `<family>jam<letter>.kf`.
func jam_clip_path() -> String:
	# ASSUMPTION: a weapon's jam clip takes its reload clip's letter. The
	# letters line up by name (1hpreloada/1hpjama); no field names a jam clip.
	var letter := _reload_letter()
	if letter.is_empty():
		return ""
	return CLIP_FOLDER + animation_family + "jam" + letter + ".kf"


## The aim clip's path, "" when the weapon has no family.
func aim_clip_path() -> String:
	if animation_family.is_empty():
		return ""
	return CLIP_FOLDER + animation_family + "aim.kf"


func _reload_letter() -> String:
	if animation_family.is_empty():
		return ""
	if RELOAD_LETTERS.has(reload_animation):
		return String(RELOAD_LETTERS[reload_animation])
	if reload_animation < 0 or reload_animation > LAST_ALPHABET_RELOAD:
		return ""
	return char("a".unicode_at(0) + reload_animation)


func action_clip_name(action: String) -> String:
	if animation_family.is_empty(): return ""
	match action.to_lower():
		"equip": return animation_family + "equip.kf"
		"unequip": return animation_family + "unequip.kf"
		"idle": return animation_family + "idle.kf"
		"block": return animation_family + "blockidle.kf"
		"holster": return animation_family + "holster.kf"
		"attack": return animation_family + "attackleft.kf"
		"reload": return animation_family + "reloada.kf"
		_: return ""
