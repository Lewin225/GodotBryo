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
## FGGS in the male FaceGen block (after the last MNAM): 50 geometry-symmetric
## coefficients. Read. Used by FaceGenServer, which adds an NPC_'s own FGGS to
## its race's for its gender.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var male_facegen_geometry_symmetric: PackedFloat32Array = PackedFloat32Array()
## FGGA in the male FaceGen block: 30 geometry-asymmetric coefficients, zero on
## every race in FalloutNV.esm. Read. Used by FaceGenServer, as FGGS.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var male_facegen_geometry_asymmetric: PackedFloat32Array = PackedFloat32Array()
## FGTS in the male FaceGen block: 50 texture-symmetric coefficients. Read.
## Used by FaceGenServer, which adds an NPC_'s own FGTS to its race's for the
## face map and body tint.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var male_facegen_texture_symmetric: PackedFloat32Array = PackedFloat32Array()
## FGGS in the female FaceGen block (after the last FNAM). Read. Used by
## FaceGenServer.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var female_facegen_geometry_symmetric: PackedFloat32Array = PackedFloat32Array()
## FGGA in the female FaceGen block. Read. Used by FaceGenServer.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var female_facegen_geometry_asymmetric: PackedFloat32Array = PackedFloat32Array()
## FGTS in the female FaceGen block. Read. Used by FaceGenServer, as the male
## block's.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var female_facegen_texture_symmetric: PackedFloat32Array = PackedFloat32Array()
## MODL of body part INDX 3 (Upper Body Texture) after NAM1 / MNAM: the male
## upper-body EGT (`Characters\_Male\UpperBodyHumanMale.egt` on every adult
## race). Read. Used by FaceGenServer for the body tint.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var male_body_egt_path: String = ""
## MODL of body part INDX 3 after NAM1 / FNAM: the female upper-body EGT. Read.
## Used by FaceGenServer.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var female_body_egt_path: String = ""
## SNAM after each FaceGen block (u16, xEdit "Unknown"; the same value in both
## blocks of every race). Not read.
var male_default_hair_color: int = 0
var female_default_hair_color: int = 0

func head_parts(female: bool) -> Array[RacePartCollection]:
	return female_head_parts if female else male_head_parts

func body_parts(female: bool) -> Array[RacePartCollection]:
	return female_body_parts if female else male_body_parts

func facegen_geometry_symmetric(female: bool) -> PackedFloat32Array:
	return female_facegen_geometry_symmetric if female else male_facegen_geometry_symmetric

func facegen_geometry_asymmetric(female: bool) -> PackedFloat32Array:
	return female_facegen_geometry_asymmetric if female else male_facegen_geometry_asymmetric

func facegen_texture_symmetric(female: bool) -> PackedFloat32Array:
	return female_facegen_texture_symmetric if female else male_facegen_texture_symmetric

func body_egt_path(female: bool) -> String:
	return female_body_egt_path if female else male_body_egt_path

## The ICON of head part `index` (0 Head) or, with `body`, body part `index`
## (0 Upper Body, 1 Left Hand, 2 Right Hand): the texture the race puts on that
## part in place of the NIF's own. Empty when the part has none.
func part_texture(female: bool, body: bool, index: int) -> String:
	var parts := body_parts(female) if body else head_parts(female)
	for part in parts:
		if part.index == index:
			return part.icon_path
	return ""
