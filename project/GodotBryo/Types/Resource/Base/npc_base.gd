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

@export_group("Skills")
## DNAM offsets 0-13: skill values, in actor value order Barter (32) through
## Unarmed (45); Big Guns is in the data though FNV does not use it. Read; used
## by ActorValues.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_barter: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_big_guns: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_energy_weapons: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_explosives: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_lockpick: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_medicine: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_melee_weapons: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_repair: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_science: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_guns: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_sneak: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_speech: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_survival: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_unarmed: int = 0

@export_group("Skill Offsets")
## DNAM offsets 14-27: skill offsets, in the same order. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_offset_barter: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_offset_big_guns: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_offset_energy_weapons: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_offset_explosives: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_offset_lockpick: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_offset_medicine: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_offset_melee_weapons: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_offset_repair: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_offset_science: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_offset_guns: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_offset_sneak: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_offset_speech: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_offset_survival: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var skill_offset_unarmed: int = 0

@export_group("Appearance")
## RNAM: the RACE FormID. Read; resolved into `race`.
var race_form_id: int = 0
## RNAM's RACE. Used: EsmActorNode takes the body and head parts from it.
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
## HNAM's HAIR. Used: EsmActorNode loads its mesh.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "HairBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var hair: HairBase
## LNAM: Hair length. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var hair_length: float = 0.0
## HCLR: Hair color (RGB bytes). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var hair_color: Color = Color.BLACK
## ENAM: the EYES FormID. Read; resolved into `eyes`.
var eyes_form_id: int = 0
## ENAM's EYES. Used: EsmActorNode loads its mesh.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EyesBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var eyes: EyesBase
## FGGS, FGGA and FGTS: FaceGen geometry-symmetric, geometry-asymmetric and
## texture-symmetric coefficients, raw and decoded. Read; not used by
## EsmActorNode yet (only the legacy GamebryoMeshResolver accepts it).
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

## DNAM skill value `index`: 0 Barter through 13 Unarmed (actor values 32-45).
func get_skill_value(index: int) -> int:
	match index:
		0: return skill_barter
		1: return skill_big_guns
		2: return skill_energy_weapons
		3: return skill_explosives
		4: return skill_lockpick
		5: return skill_medicine
		6: return skill_melee_weapons
		7: return skill_repair
		8: return skill_science
		9: return skill_guns
		10: return skill_sneak
		11: return skill_speech
		12: return skill_survival
		13: return skill_unarmed
	return 0

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
## not followed. Used by EsmActorNode (body parts, biped models) and
## GetIsSex.
func is_female() -> bool:
	return (acbs_flags & FLAG_FEMALE) != 0

## Sets or clears the ACBS Female flag (SexChange, the race menu) and marks
## the record dirty.
func set_female(female: bool) -> void:
	acbs_flags = (acbs_flags | FLAG_FEMALE) if female else (acbs_flags & ~FLAG_FEMALE)
	mark_dirty()

## RNAM's RACE body parts (required) and head parts, then HNAM's hair and
## ENAM's eyes (optional), for the actor node.
func get_model_parts(female: bool) -> Array[Dictionary]:
	var parts: Array[Dictionary] = []
	if race == null:
		# A required part with no model: the actor node reports it and builds
		# nothing.
		parts.append({"key": "race", "path": "", "required": true, "kind": "body"})
	else:
		for part in race.body_parts(female):
			parts.append({"key": "body:%d" % int(part.index), "path": part.model_path, "required": true, "kind": "body",
				"race_part_index": int(part.index)})
		for part in race.head_parts(female):
			parts.append({"key": "head:%d" % int(part.index), "path": part.model_path, "required": false, "kind": "head",
				"part_type": String(part.part_type)})
	if hair != null:
		parts.append({"key": "hair", "path": hair.model_path, "required": false, "kind": "hair"})
	if eyes != null:
		parts.append({"key": "eyes", "path": eyes.model_path, "required": false, "kind": "eyes"})
	return parts

func animation_search_paths() -> PackedStringArray:
	return PackedStringArray([DEFAULT_THIRD_PERSON_ANIMATION_SEARCH_PATH])
