@tool
class_name RaceBase
extends EsmBase

## DATA flag bits (xEdit FNV RACE).
const FLAG_PLAYABLE := 0x01
const FLAG_CHILD := 0x04

## RACE's four marker-delimited appearance collections. Head indices are the
## fopdoc-defined Head/Ears/Mouth/Teeth Lower/Teeth Upper/Tongue/Left Eye/
## Right Eye values; body indices are Upper Body/Left Hand/Right Hand/Upper
## Body Texture. Entries without a real mesh remain represented when the
## native query returns them (for example icon-only ears).
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "RacePartCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var male_head_parts: Array[RacePartCollection] = []
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "RacePartCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var female_head_parts: Array[RacePartCollection] = []
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "RacePartCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var male_body_parts: Array[RacePartCollection] = []
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "RacePartCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var female_body_parts: Array[RacePartCollection] = []

var older_race_form_id: int = 0
var younger_race_form_id: int = 0
var hair_form_ids: Array[int] = []
var eyes_form_ids: Array[int] = []
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "HairBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var hairs: Array[HairBase] = []
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "EyesBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var eyes: Array[EyesBase] = []
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "HairBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var male_default_hair: HairBase
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "HairBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var female_default_hair: HairBase
var male_voice_form_id: int = 0
var female_voice_form_id: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var male_height: float = 0.0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var female_height: float = 0.0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var male_weight: float = 0.0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var female_weight: float = 0.0
## DATA's flags (xEdit: Playable, Child). Read; Child used by the condition
## function IsChild.
@export_custom(PROPERTY_HINT_FLAGS, "Playable:1,Child:4", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var facegen_main_clamp: float = 0.0
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var facegen_face_clamp: float = 0.0
var male_default_hair_color: int = 0
var female_default_hair_color: int = 0

func head_parts(female: bool) -> Array[RacePartCollection]:
	return female_head_parts if female else male_head_parts

func body_parts(female: bool) -> Array[RacePartCollection]:
	return female_body_parts if female else male_body_parts
