@tool
class_name NpcBase
extends EsmBase


const DEFAULT_HUMAN_BODY_PART_DATA_FORM_ID := 0x0000001D
## ACBS flag: the NPC is female.
const FLAG_FEMALE := 0x01
# The shipped third-person humanoid animation library is conventionally named
# `_male`; it is a shared asset root, not a branch on this record's sex flag.
# No official NPC_ record supplies KFFZ (4,222-record master census), so the
# default belongs here. A future KFFZ override can prepend its exact clips
# without teaching NifServer how actors select animations.
const DEFAULT_THIRD_PERSON_ANIMATION_SEARCH_PATH := "meshes/characters/_male/"

## MODL: the skeleton NIF. Read; EsmHumanoidActor builds the skeleton from it.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
## RNAM: the RACE FormID. Read; resolved into `race`.
var race_form_id: int = 0
## HNAM: the HAIR FormID. Read; resolved into `hair`.
var hair_form_id: int = 0
## ENAM: the EYES FormID. Read; resolved into `eyes`.
var eyes_form_id: int = 0
## CNAM: the CLAS FormID. Read; resolved into `actor_class`.
var class_form_id: int = 0
## RNAM's RACE. Used: EsmHumanoidActor takes the body and head parts from it.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "RaceBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var race: RaceBase
## HNAM's HAIR. Used: EsmHumanoidActor loads its mesh.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "HairBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var hair: HairBase
## ENAM's EYES. Used: EsmHumanoidActor loads its mesh.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EyesBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var eyes: EyesBase
## CNAM's CLAS. Read; not used yet (class tag skills, services, training).
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "ClassBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var actor_class: ClassBase
## Not an NPC_ field. NPC_ records name no BPTD, while CREA records do (PNAM);
## humanoids use the unreferenced BPTD 0x0000001D (0x0000001C for the player),
## set here for every NPC_ so an NPC has its body part data where a creature
## does. Body part data maps an actor's body for damage, dismemberment and
## VATS. Set; not used yet.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "BodyPartDataBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var body_part_data: BodyPartDataBase
## PKID: the AI packages, in authored order. Read; not used yet (package
## selection is not implemented).
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "PackageBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var packages: Array[PackageBase] = []
## Not an NPC_ field: whether the NPC is a child, which the RACE's DATA flags
## (Child) would decide. Not read; always false, and not used.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var is_child: bool = false
## ACBS offset 0: the NPC_ flags, named as xEdit names them (bit 28, set on
## 1 NPC_ in FalloutNV.esm, is its Unknown 28). Read; Female is read by
## is_female() and changed by set_female() (SexChange, the race menu); the
## rest are not used yet. Also held in `actor_stats.flags`.
@export_custom(PROPERTY_HINT_FLAGS, "Female:1,Essential:2,Is CharGen Face Preset:4,Respawn:8,Auto-calc Stats:16,PC Level Mult:128,Use Template:256,No Low Level Processing:512,No Blood Spray:2048,No Blood Decal:4096,No VATS Melee:1048576,Can Be All Races:4194304,Autocalc Service:8388608,No Knockdowns:67108864,Not Pushable:134217728,Unknown 28:268435456,No Rotating To Head-track:1073741824", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var acbs_flags: int = 0
## ACBS offset 22: which parts come from the TPLT template (xEdit
## `wbTemplateFlags`). Read; not used yet from here (ActorStats holds the same
## value and follows Stats). Also held in `actor_stats.template_flags`.
@export_custom(PROPERTY_HINT_FLAGS, "Traits:1,Stats:2,Factions:4,Actor Effect List:8,AI Data:16,AI Packages:32,Model/Animation:64,Base Data:128,Inventory:256,Script:512", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var acbs_template_flags: int = 0
## FGGS, FGGA and FGTS: FaceGen geometry-symmetric, geometry-asymmetric and
## texture-symmetric coefficients, raw and decoded. Read; not used by
## EsmHumanoidActor yet (only the legacy GamebryoMeshResolver accepts it).
var face_gen: FaceGenData
## ACBS, DATA, DNAM and AIDT, plus TPLT: level, SPECIAL, skills, base health,
## AI traits and the stats template. Read; used by ActorValues to derive the
## actor's base values.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "ActorStats", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var actor_stats: ActorStats
## VTCK: the VTYP voice type FormID, on all 3,816 NPC_ records in FalloutNV.esm;
## 0 when absent. Read, from this record; with the Traits template flag the
## template's is used (ActorStats.template_source). Used by GetIsVoiceType.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var voice_type_form_id: int = 0
## SNAM: the factions and the actor's rank in each, in authored order (14,625
## SNAM on NPC_ and CREA in FalloutNV.esm). Read, from this record; with the
## Factions template flag the template's are used. Used by GetInFaction and
## GetFactionRank; runtime changes (SetFactionRank, AddToFaction) are not
## implemented.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "ActorFaction", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var factions: Array[ActorFaction] = []

## Whether this record's ACBS flags it Female. A template supplying traits is
## not followed. Used by EsmHumanoidActor (body parts, biped models) and
## GetIsSex.
func is_female() -> bool:
	return (acbs_flags & FLAG_FEMALE) != 0

## Sets or clears the ACBS Female flag (SexChange, the race menu) and marks
## the record dirty.
func set_female(female: bool) -> void:
	acbs_flags = (acbs_flags | FLAG_FEMALE) if female else (acbs_flags & ~FLAG_FEMALE)
	mark_dirty()

func animation_search_paths() -> PackedStringArray:
	return PackedStringArray([DEFAULT_THIRD_PERSON_ANIMATION_SEARCH_PATH])
