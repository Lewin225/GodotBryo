@tool
class_name NpcBase
extends EsmBase


const DEFAULT_HUMAN_BODY_PART_DATA_FORM_ID := 0x0000001D

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var model_path: String = ""
var race_form_id: int = 0
var hair_form_id: int = 0
var eyes_form_id: int = 0
var class_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "RaceBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var race: RaceBase
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "HairBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var hair: HairBase
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EyesBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var eyes: EyesBase
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "ClassBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var actor_class: ClassBase
# Body part data, defines how an actor's body is mapped, damaged, and targeted in VATS
# This is fake. NPC_ records in the ESM don't actually have a BPDT reference, yet creatures and ragdolls do
# Humanoid body part data comes from an unreferenced BPDT record at 0x0000001D (and 0000001C for players)
# I haardcoded it to appear here because that's where you'd expect it to be
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "BodyPartDataBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var body_part_data: BodyPartDataBase
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "PackageBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var packages: Array[PackageBase] = []
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var is_female: bool = false
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var is_child: bool = false
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var acbs_flags: int = 0
var face_gen: FaceGenData
