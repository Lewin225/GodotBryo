@tool
class_name NpcBase
extends ActorBase


const DEFAULT_HUMAN_BODY_PART_DATA_FORM_ID := 0x0000001D
## ACBS flag: the NPC is female.
const FLAG_FEMALE := 0x01
# The shipped third-person humanoid animation library is conventionally named
# `_male`; it is a shared asset root, not a branch on this record's sex flag.
# No official NPC_ record supplies KFFZ (4,222-record master census), so the
# default belongs here. A future KFFZ override can prepend its exact clips
# without teaching NifServer how actors select animations.
const DEFAULT_THIRD_PERSON_ANIMATION_SEARCH_PATH := "meshes/characters/_male/"

## ACBS flag names on NPC_ (xEdit; bit 28, set on 1 NPC_ in FalloutNV.esm, is
## its Unknown 28).
const ACBS_FLAG_NAMES := "Female:1,Essential:2,Is CharGen Face Preset:4,Respawn:8,Auto-calc Stats:16,PC Level Mult:128,Use Template:256,No Low Level Processing:512,No Blood Spray:2048,No Blood Decal:4096,No VATS Melee:1048576,Can Be All Races:4194304,Autocalc Service:8388608,No Knockdowns:67108864,Not Pushable:134217728,Unknown 28:268435456,No Rotating To Head-track:1073741824"

@export_group("Stats")
## DATA offset 0: Base Health (s32). Read; used by ActorValues (Health).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var base_health: int = 0
## DATA offsets 4-10: Strength, Perception, Endurance, Charisma, Intelligence,
## Agility, Luck. Read; used by ActorValues.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var attributes := PackedInt32Array([0, 0, 0, 0, 0, 0, 0])
## DNAM offsets 0-13: skill values, Barter (actor value 32) through Unarmed
## (45). Read; used by ActorValues.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_values := PackedInt32Array()
## DNAM offsets 14-27: skill offsets, in the same order. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_offsets := PackedInt32Array()

@export_group("Appearance")
## RNAM: the RACE FormID. Read; resolved into `race`.
var race_form_id: int = 0
## RNAM's RACE. Used: EsmHumanoidActor takes the body and head parts from it.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "RaceBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var race: RaceBase
## CNAM: the CLAS FormID. Read; resolved into `actor_class`.
var class_form_id: int = 0
## CNAM's CLAS. Read; not used yet (class tag skills, services, training).
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "ClassBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var actor_class: ClassBase
## PNAM, repeated: the NPC's own head parts. Read; not used yet (the humanoid
## head comes from RACE).
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "HeadPartBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var head_parts: Array[HeadPartBase] = []
## HNAM: the HAIR FormID. Read; resolved into `hair`.
var hair_form_id: int = 0
## HNAM's HAIR. Used: EsmHumanoidActor loads its mesh.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "HairBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var hair: HairBase
## LNAM: Hair length. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var hair_length: float = 0.0
## HCLR: Hair color (RGB bytes). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var hair_color: Color = Color.BLACK
## ENAM: the EYES FormID. Read; resolved into `eyes`.
var eyes_form_id: int = 0
## ENAM's EYES. Used: EsmHumanoidActor loads its mesh.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EyesBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var eyes: EyesBase
## FGGS, FGGA and FGTS: FaceGen geometry-symmetric, geometry-asymmetric and
## texture-symmetric coefficients, raw and decoded. Read; not used by
## EsmHumanoidActor yet (only the legacy GamebryoMeshResolver accepts it).
var face_gen: FaceGenData
## NAM6: Height. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var height: float = 1.0
## NAM7: Weight. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var weight: float = 0.0

@export_group("Other")
## NAM5 (u16; xEdit: Unknown). Read; not used.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var unknown_nam5: int = 0
## Not an NPC_ field. NPC_ records name no BPTD, while CREA records do (PNAM);
## humanoids use the unreferenced BPTD 0x0000001D (0x0000001C for the player),
## set here for every NPC_ so an NPC has its body part data where a creature
## does. Body part data maps an actor's body for damage, dismemberment and
## VATS. Set; not used yet.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "BodyPartDataBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var body_part_data: BodyPartDataBase
## Not an NPC_ field: whether the NPC is a child, which the RACE's DATA flags
## (Child) would decide. Not read; always false, and not used.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var is_child: bool = false
@export_group("")

func _validate_property(property: Dictionary) -> void:
	if property.name == "acbs_flags":
		property.hint_string = ACBS_FLAG_NAMES

## Activating an NPC: the player starts a conversation with it (GREETING).
## Another activator does nothing.
func activate(ref: EsmReference, activator: EsmReference) -> void:
	if ref == null or activator == null or activator != ScriptServer.player_reference:
		return
	DialogueServer.start_conversation(ref, activator)

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
