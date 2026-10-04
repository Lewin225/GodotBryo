@tool
class_name CreatureSoundCollection
extends Resource

## One CREA sound: CSDT, CSDI, CSDC (xEdit "Sound Type"; on 86 CREA in
## FalloutNV.esm).

## CSDT: the sound type (xEdit: Left Foot, Right Foot, Left Back Foot, Right
## Back Foot, Idle, Aware, Attack, Hit, Death, Weapon, Movement Loop, Conscious
## Loop, Auxiliary 1-8, Jump, PlayRandom/Loop). Read; not used yet.
@export_custom(PROPERTY_HINT_ENUM, "Left Foot,Right Foot,Left Back Foot,Right Back Foot,Idle,Aware,Attack,Hit,Death,Weapon,Movement Loop,Conscious Loop,Auxiliary 1,Auxiliary 2,Auxiliary 3,Auxiliary 4,Auxiliary 5,Auxiliary 6,Auxiliary 7,Auxiliary 8,Jump,PlayRandom/Loop", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var sound_type: int = 0
## CSDI: the sound. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var sound_form_id: int = 0
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "SoundBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var sound: SoundBase
## CSDC: chance (u8). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var chance: int = 0
