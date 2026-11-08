@tool
class_name WeaponBase
extends EsmBase

## DNAM Flags 1 bits, xEdit's names.
const FLAGS1_NAMES := "Ignores Normal Weapon Resistance:1,Is Automatic:2,Has Scope:4,Can't Drop:8,Hide Backpack:16,Embedded Weapon:32,Don't Use 1st Person IS Animations:64,Non-Playable:128"
const FLAG1_IS_AUTOMATIC := 0x02
const FLAG1_HIDE_BACKPACK := 0x10
## DNAM Flags 2 bits, xEdit's names.
const FLAGS2_NAMES := "Player Only:1,NPCs Use Ammo:2,No Jam After Reload:4,Override - Action Points:8,Minor Crime:16,Range - Fixed:32,Not Used In Normal Combat:64,Override - Damage to Weapon Mult:128,Don't Use 3rd Person IS Animations:256,Short Burst:512,Rumble Alternate:1024,Long Burst:2048,Scope has NightVision:4096,Scope from Mod:8192"
const FLAG2_NO_JAM_AFTER_RELOAD := 0x04


## MODL: the world model. Read; used by EsmWeaponNode (its model).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
## MODS: Alternate Textures for MODL. On 1 of 261 WEAP in FalloutNV.esm.
## Read; not used yet (NifServer would swap the named shapes' texture sets).
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "AlternateTextureCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var alternate_textures: Array[AlternateTextureCollection] = []
## WNAM: the STAT whose model is the viewmodel (1st Person Model). Read; not
## used yet (the viewmodel step of Plans/Weapons/weapons.md).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var first_person_form_id: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var value: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var health: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var weight: float = 0.0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var base_damage: int = 0
## DATA offset 14: rounds a full clip holds. Read; used by EsmWeaponNode's
## reload.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var clip_size: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var equipment_type: int = 0
## DNAM offset 0: Animation Type. Read; used through animation_family.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var animation_type: int = -1
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var biped_model_list_form_id: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var inventory_icon: String = ""
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var message_icon: String = ""
## Not an ESM field: the clip family animation_type maps to (1hp, 2hr, ...),
## the prefix of the weapon's clips. Set with animation_type; used by the clip
## paths below and holsters_on_back().
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var animation_family: String = ""
## DNAM offset 41: Attack Animation (xEdit's enum, 255 DEFAULT). Read; used
## by attack_clip_path().
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var attack_animation: int = 255
## DNAM offset 15: Reload Animation (0 to 16 a to q, 20 to 22 x to z). Read;
## used by reload_clip_path() and jam_clip_path().
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var reload_animation: int = 255
## DNAM offset 13: Grip Animation (230 to 235 HandGrip1 to 6, 255 DEFAULT).
## Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var grip_animation: int = 255
## BIPL: the FLST of biped models worn while equipped (power fists, gloves).
## Read; used by ActorEquipment.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "FormListBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var biped_model_list: Resource
## NAM0: the AMMO it fires, or a FLST of AMMO it accepts (143 and 145 of the
## 288 WEAP with NAM0 in the six ESMs; 214 of the 502 have none). Read; not used yet (the
## weapon node's reload, Plans/Weapons/weapons.md step 7).
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var ammo: EsmBase
## NAM0's FormID, 0 when absent. Read; resolved into `ammo`.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var ammo_form_id: int = 0
## DNAM offset 4: Animation Multiplier, the speed of the weapon's clips. Read;
## not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var animation_multiplier: float = 1.0
## DNAM offset 8: Reach. Read; not used yet (melee).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var reach: float = 0.0
## DNAM offset 12: Flags 1 (FLAGS1_NAMES). Read; not used yet (Is Automatic by
## the weapon node's fire; Hide Backpack's meaning is not known: it is set on
## heavy weapons whose backpacks show).
@export_custom(PROPERTY_HINT_FLAGS, FLAGS1_NAMES, PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags1: int = 0
## DNAM offset 14: Ammo Use, rounds spent per shot. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var ammo_use: int = 1
## DNAM offset 16: Min Spread. Read; not used yet (ProjectileServer).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var min_spread: float = 0.0
## DNAM offset 20: Spread. Read; not used yet (ProjectileServer).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var spread: float = 0.0
## DNAM offset 28: Sight FOV. Read; not used yet (aiming).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var sight_fov: float = 0.0
## DNAM offset 36: the PROJ fired. Read; not used yet (ProjectileServer).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var projectile_form_id: int = 0
## DNAM offset 42: Projectile Count per shot. Read; not used yet
## (ProjectileServer).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var projectile_count: int = 1
## DNAM offset 44: Min Range. Read; not used yet (NPC combat).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var min_range: float = 0.0
## DNAM offset 48: Max Range. Read; not used yet (NPC combat).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var max_range: float = 0.0
## DNAM offset 56: Flags 2 (FLAGS2_NAMES). Read; not used yet.
@export_custom(PROPERTY_HINT_FLAGS, FLAGS2_NAMES, PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags2: int = 0
## DNAM offset 60: Animation Attack Multiplier, the attack clip's speed. Read;
## not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var animation_attack_multiplier: float = 1.0
## DNAM offset 64: Fire Rate. Read; not used yet (the weapon node's fire).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var fire_rate: float = 0.0
## DNAM offset 88: Attack Shots/Sec. Read; not used yet (the weapon node's
## fire).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var attack_shots_per_second: float = 0.0
## DNAM offset 92: Reload Time, seconds. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var reload_time: float = 0.0
## DNAM offset 96: Jam Time, seconds. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var jam_time: float = 0.0
## DNAM offset 100: Aim Arc. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var aim_arc: float = 0.0
## DNAM offset 128: Semi-Automatic Fire Delay Min, seconds. Read; not used yet
## (the weapon node's fire).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var semi_automatic_fire_delay_min: float = 0.0
## DNAM offset 132: Semi-Automatic Fire Delay Max, seconds. Read; not used
## yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var semi_automatic_fire_delay_max: float = 0.0
## CRDT offset 0: Critical Damage. Read; not used yet (damage).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var critical_damage: int = 0
## CRDT offset 4: Crit % Mult. Read; not used yet (damage).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var critical_chance_multiplier: float = 0.0
## CRDT offset 8: Flags, 0x01 On Death. Read; not used yet.
@export_custom(PROPERTY_HINT_FLAGS, "On Death:1", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var critical_flags: int = 0
## CRDT offset 12: the SPEL a critical hit applies, 0 for none. Read; not used
## yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var critical_effect_form_id: int = 0

## Where a holstered weapon of a family hangs, from its `<family>holster.kf`
## `prn:` key (census of the 16 `_male` holster clips): `Bip01 Pelvis` (1gt,
## 1hm, 1hp, 1lm, 1md) a hip slot, `Bip01 Spine2` (2ha, 2hl, 2hm, 2hr) the back.
## 2hh keeps the weapon on `Bip01 R Hand`, its backpack on `Bip01 Spine2`, so it
## takes the back slot; h2h keeps it on `Bip01 R ForeTwist`.
const LONG_FAMILIES := ["2ha", "2hh", "2hl", "2hm", "2hr"]


## Whether the weapon holsters in the back slot (a long gun, or a heavy weapon's
## backpack) rather than a hip slot.
func holsters_on_back() -> bool:
	return LONG_FAMILIES.has(animation_family)


## The holster clip's path, "" when the weapon has no family.
func holster_clip_path() -> String:
	if animation_family.is_empty():
		return ""
	return CLIP_FOLDER + animation_family + "holster.kf"


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
