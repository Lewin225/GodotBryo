@tool
class_name ArmorBase
extends EsmBase

const BIPED_HEAD := 0x00000001
const BIPED_HAIR := 0x00000002
const BIPED_UPPER_BODY := 0x00000004
const BIPED_LEFT_HAND := 0x00000008
const BIPED_RIGHT_HAND := 0x00000010
const BIPED_HEADBAND := 0x00000200
const BIPED_HAT := 0x00000400
const EQUIPMENT_TYPE_NONE := -1
const EQUIPMENT_TYPE_BIG_GUNS := 0
const EQUIPMENT_TYPE_ENERGY_WEAPONS := 1
const EQUIPMENT_TYPE_SMALL_GUNS := 2
const EQUIPMENT_TYPE_MELEE_WEAPONS := 3
const EQUIPMENT_TYPE_UNARMED_WEAPON := 4
const EQUIPMENT_TYPE_THROWN_WEAPONS := 5
const EQUIPMENT_TYPE_MINE := 6
const EQUIPMENT_TYPE_BODY_WEAR := 7
const EQUIPMENT_TYPE_HEAD_WEAR := 8
const EQUIPMENT_TYPE_HAND_WEAR := 9
const EQUIPMENT_TYPE_CHEMS := 10
const EQUIPMENT_TYPE_STIMPACK := 11
const EQUIPMENT_TYPE_FOOD := 12
const EQUIPMENT_TYPE_ALCOHOL := 13
const EQUIPMENT_TYPE_NAMES := "None:-1,Big Guns:0,Energy Weapons:1,Small Guns:2,Melee Weapons:3,Unarmed Weapon:4,Thrown Weapons:5,Mine:6,Body Wear:7,Head Wear:8,Hand Wear:9,Chems:10,Stimpack:11,Food:12,Alcohol:13"
const BIPED_FLAG_NAMES := "Head:1,Hair:2,Upper Body:4,Left Hand:8,Right Hand:16,Weapon:32,PipBoy:64,Backpack:128,Necklace:256,Headband:512,Hat:1024,Eye Glasses:2048,Nose Ring:4096,Earrings:8192,Mask:16384,Choker:32768,Mouth Object:65536,Body AddOn 1:131072,Body AddOn 2:262144,Body AddOn 3:524288"

## MOD2: the male world model, the NIF shown when the armour lies in the
## world. Read (a copy of `male_world_model`); used by EsmNode to build a
## placed ARMO.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
## DATA offset 0 (s32): the value in caps. Read; not used yet (barter).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var value: int = 0
## DATA offset 8 (f32): the inventory weight. Read; not used yet (carry
## weight). DATA offset 4 is the armour's health (max condition), not read.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var weight: float = 0.0
## DNAM offset 0 (s16, hundredths): the damage resistance, in percent. Read;
## not used yet (damage). Non-zero on 9 of 389 ARMO in FalloutNV.esm, all whole
## percents. DNAM offset 2, flag 0x1 (Modulates Voice, on 12), is not read.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var armor_rating: int = 0
## DNAM offset 4 (f32): the damage threshold. Read; not used yet (damage).
## Present on 368 of 389 ARMO (the other 21 DNAM are 4 bytes), always a whole
## number.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var damage_threshold: int = 0
## BMDT biped flags: the body slots the armour covers. Read; used by
## ActorEquipment to drop later armour on an occupied slot, and by
## EsmActorNode to hide covered body parts and to show the hat hair under Hat.
## BMDT offset 4 (general flags: Power Armor, Non-Playable, Heavy, ...) is not
## read.
@export_custom(PROPERTY_HINT_FLAGS, BIPED_FLAG_NAMES, PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var biped_flags: int = 0
## ETYP (s32): the equipment type. On every ARMO in FalloutNV.esm: Body Wear on
## 238, Head Wear on 135, Big Guns (0) on the 15 animation-sound templates and
## Chems on one token. Read; not used yet (inventory categories, AI equip
## choice).
@export_custom(PROPERTY_HINT_ENUM, EQUIPMENT_TYPE_NAMES, PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var equipment_type: int = EQUIPMENT_TYPE_NONE
## MODL: the male biped model, worn on the body. Read; used by ActorEquipment.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var male_biped_model: String = ""
## MODS: Alternate Textures for MODL. On 51 of 389 ARMO in FalloutNV.esm.
## Read; not used yet (NifServer would swap the named shapes' texture sets).
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "AlternateTextureCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var male_biped_alternate_textures: Array[AlternateTextureCollection] = []
## MOD2: the male world model. Read; used through `model_path`.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var male_world_model: String = ""
## MO2S: Alternate Textures for MOD2. On 54 of 389 ARMO in FalloutNV.esm.
## Read; not used yet (NifServer would swap the named shapes' texture sets).
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "AlternateTextureCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var male_world_alternate_textures: Array[AlternateTextureCollection] = []
## MOD3: the female biped model. Read; used by ActorEquipment for female
## actors.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var female_biped_model: String = ""
## MO3S: Alternate Textures for MOD3. On 47 of 389 ARMO in FalloutNV.esm.
## Read; not used yet (NifServer would swap the named shapes' texture sets).
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "AlternateTextureCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var female_biped_alternate_textures: Array[AlternateTextureCollection] = []
## MOD4: the female world model. Read; not used (a placed ARMO shows the male
## world model).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var female_world_model: String = ""
## MO4S: Alternate Textures for MOD4. On 10 of 389 ARMO in FalloutNV.esm.
## Read; not used yet (NifServer would swap the named shapes' texture sets).
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "AlternateTextureCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var female_world_alternate_textures: Array[AlternateTextureCollection] = []
## BIPL: the FormID of the biped model list (FLST of ARMA). Read; resolved
## into `biped_model_list`.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var biped_model_list_form_id: int = 0
## BIPL resolved: the armour addons worn with the armour. Read; used by
## ActorEquipment, which builds each ARMA's biped model.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "FormListBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var biped_model_list: Resource
