@tool
class_name CreatureBase
extends ActorBase

## CREA (Creature): ActorBase plus the CREA-only fields and the CREA meanings of
## DATA, RNAM, PNAM, CNAM, NAM5 and LNAM.

## ACBS flag names on CREA (xEdit; bit 27 is both Not Pushable and Allow
## Pickpocket there).
const ACBS_FLAG_NAMES := "Biped:1,Essential:2,Weapon & Shield?:4,Respawn:8,Swims:16,Flies:32,Walks:64,PC Level Mult:128,No Low Level Processing:512,No Blood Spray:2048,No Blood Decal:4096,No Head:32768,No Right Arm:65536,No Left Arm:131072,No Combat in Water:262144,No Shadow:524288,No VATS Melee:1048576,Allow PC Dialogue:2097152,Can't Open Doors:4194304,Immobile:8388608,Tilt Front/Back:16777216,Tilt Left/Right:33554432,No Knockdowns:67108864,Not Pushable / Allow Pickpocket:134217728,Is Ghost:268435456,No Rotating To Head-track:536870912,Invulnerable:1073741824"

@export_group("Stats")
## DATA offset 0: Type (xEdit `wbCreatureTypeEnum`). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var creature_type: int = 0
## DATA offsets 1-3: Combat, Magic and Stealth Skill. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var combat_skill: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var magic_skill: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var stealth_skill: int = 0
## DATA offset 4: Health (s16). Read; used by ActorValues (Health).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var health: int = 0
## DATA offset 8: Damage (s16). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var damage: int = 0
## DATA offsets 10-16: the SPECIAL attributes, on ActorBase.

@export_group("Combat")
## RNAM: Attack reach (u8). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var attack_reach: int = 0
## LNAM: the melee weapon list. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var melee_weapon_list_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "FormListBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var melee_weapon_list: FormListBase

@export_group("Body")
## NIFZ: the body-part NIFs, file names relative to MODL's folder (1,059 CREA in
## FalloutNV.esm). Read; not used yet (the actors plan's stage J).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_list: PackedStringArray = PackedStringArray()
## Not an ESM field: `model_list` joined to MODL's folder. Set; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_list_paths: PackedStringArray = PackedStringArray()
## NIFT: Model List Textures, raw (texture-file hashes for `model_list`).
## Read; not used.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_list_textures: PackedByteArray = PackedByteArray()
## PNAM: the body part data. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var body_part_data_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "BodyPartDataBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var body_part_data: BodyPartDataBase
## TNAM: Turning Speed. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var turning_speed: float = 0.0
## BNAM: Base Scale. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var base_scale: float = 1.0
## WNAM: Foot Weight. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var foot_weight: float = 0.0

@export_group("Sound")
## NAM5: Sound Level. Read; not used yet.
@export_custom(PROPERTY_HINT_ENUM, "Loud,Normal,Silent", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var sound_level: int = 1
## CNAM: the impact dataset. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var impact_dataset_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "ImpactDatasetBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var impact_dataset: ImpactDatasetBase
## CSCR: the creature whose sounds this one inherits. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var inherits_sounds_from_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "CreatureBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var inherits_sounds_from: CreatureBase
## CSDT / CSDI / CSDC, one collection per sound. Read; not used yet.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "CreatureSoundCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var sounds: Array[CreatureSoundCollection] = []
@export_group("")

func _validate_property(property: Dictionary) -> void:
	if property.name == "acbs_flags":
		property.hint_string = ACBS_FLAG_NAMES
