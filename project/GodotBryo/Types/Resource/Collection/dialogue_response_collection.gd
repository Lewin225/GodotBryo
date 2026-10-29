@tool
class_name DialogueResponseCollection
extends Resource

## Not an ESM record. One INFO response, a TRDT and the NAM1, NAM2, NAM3, SNAM
## and LNAM after it; added so each response keeps its own text and data. The
## responses of an INFO play in authored order.

enum Emotion { NEUTRAL, ANGER, DISGUST, FEAR, SAD, HAPPY, SURPRISE, PAINED }

## TRDT offset 0. Read; used by ActorFacialPlayer as the morph shown while
## the response is said.
@export_custom(PROPERTY_HINT_ENUM, "Neutral,Anger,Disgust,Fear,Sad,Happy,Surprise,Pained", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var emotion: Emotion = Emotion.NEUTRAL
## TRDT offset 4: the emotion's strength, 0 to 100. Read; used by
## ActorFacialPlayer as the morph's weight (value / 100).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var emotion_value: int = 0
## TRDT offset 12: the response number, which names its voice file. Read; not
## used yet (voice file paths).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var response_number: int = 0
## TRDT offset 16: a SOUN FormID. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var sound_form_id: int = 0
## TRDT offset 20: Use Emotion Animation. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var uses_emotion_animation: bool = false
## NAM1: the line spoken. Read; not used yet (subtitles and the conversation
## menu).
@export_custom(PROPERTY_HINT_MULTILINE_TEXT, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var text: String = ""
## NAM2: the writer's script notes. Read; not used.
@export_custom(PROPERTY_HINT_MULTILINE_TEXT, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var script_notes: String = ""
## NAM3: edits. Read; not used.
@export_custom(PROPERTY_HINT_MULTILINE_TEXT, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var edits: String = ""
## SNAM: the speaker's IDLE, on 320 INFOs in FalloutNV.esm. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var speaker_idle_form_id: int = 0
## LNAM: the listener's IDLE, on 1 INFO. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var listener_idle_form_id: int = 0
