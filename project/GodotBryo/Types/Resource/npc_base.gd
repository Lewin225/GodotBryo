@tool
class_name NpcBase
extends EsmBase


const DEFAULT_HUMAN_BODY_PART_DATA_FORM_ID := 0x0000001D
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
## ACBS flag 0x01 (Female). Read; used by EsmHumanoidActor to choose male or
## female body parts and biped models.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var is_female: bool = false
## Not an NPC_ field: whether the NPC is a child, which the RACE's DATA flags
## (Child) would decide. Not read; always false, and not used.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var is_child: bool = false
## ACBS flags (offset 0). Read; used only to set `is_female`. Also held in
## `actor_stats.flags`.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var acbs_flags: int = 0
## FGGS, FGGA and FGTS: FaceGen geometry-symmetric, geometry-asymmetric and
## texture-symmetric coefficients, raw and decoded. Read; not used by
## EsmHumanoidActor yet (only the legacy GamebryoMeshResolver accepts it).
var face_gen: FaceGenData
## ACBS, DATA, DNAM and AIDT, plus TPLT: level, SPECIAL, skills, base health,
## AI traits and the stats template. Read; used by ActorValues to derive the
## actor's base values.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "ActorStats", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var actor_stats: ActorStats

func animation_search_paths() -> PackedStringArray:
	return PackedStringArray([DEFAULT_THIRD_PERSON_ANIMATION_SEARCH_PATH])
