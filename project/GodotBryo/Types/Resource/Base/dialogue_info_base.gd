@tool
class_name DialogueInfoBase
extends EsmBase

## INFO record: one thing an actor can say in a topic, with its conditions,
## responses, links and result scripts. INFO records have no EDID.

const FLAG_GOODBYE := 0x01
const FLAG_RANDOM := 0x02
const FLAG_SAY_ONCE := 0x04
const FLAG_RUN_IMMEDIATELY := 0x08
const FLAG_INFO_REFUSAL := 0x10
const FLAG_RANDOM_END := 0x20
const FLAG_RUN_FOR_RUMORS := 0x40
const FLAG_SPEECH_CHALLENGE := 0x80
const FLAG_SAY_ONCE_A_DAY := 0x01
const FLAG_ALWAYS_DARKEN := 0x02
const FLAG_LOW_INTELLIGENCE := 0x10
const FLAG_HIGH_INTELLIGENCE := 0x20

## Not an INFO field: the DIAL whose child GRUP holds this INFO (TPIC, which
## would name it, is absent from FalloutNV.esm's INFOs). Set from the record
## index; used by DialogueServer to say a follow-up INFO in its own topic.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var topic_form_id: int = 0
## QSTI: the quest this INFO belongs to, on every INFO. Read; resolved into
## `quest`.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var quest_form_id: int = 0
## QSTI's QUST. Not used yet (an INFO is available while its quest runs, and
## is ordered by the quest's priority).
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "QuestBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var quest: QuestBase
## DATA byte 0; differs from its topic's type on 803 INFOs in FalloutNV.esm.
## Read; not used yet.
@export_custom(PROPERTY_HINT_ENUM, "Topic,Conversation,Combat,Persuasion,Detection,Service,Miscellaneous,Radio", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var info_type: DialogueTopicBase.Type = DialogueTopicBase.Type.TOPIC
## DATA byte 1: the next speaker (xEdit `wbNextSpeaker`: 0 Target, 1 Self,
## 2 Either). Read; not used yet.
@export_custom(PROPERTY_HINT_ENUM, "Target,Self,Either", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var next_speaker: int = 0
## DATA byte 2: flags. Read; not used yet (Goodbye ends a conversation, Say
## Once and Random steer which INFO is chosen).
@export_custom(PROPERTY_HINT_FLAGS, "Goodbye:1,Random:2,Say Once:4,Run Immediately:8,Info Refusal:16,Random End:32,Run for Rumors:64,Speech Challenge:128", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
## DATA byte 3: more flags. Read; not used yet.
@export_custom(PROPERTY_HINT_FLAGS, "Say Once a Day:1,Always Darken:2,Unknown 0x04:4,Unknown 0x08:8,Low Intelligence:16,High Intelligence:32", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags_2: int = 0
## TRDT and the subrecords after each: the responses, in the order they are
## spoken; 1 on 19,025 INFOs, up to 31, none on 9. Read; not used yet.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "DialogueResponseCollection", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var responses: Array[DialogueResponseCollection] = []
## CTDA: who may say this and when, on 22,471 INFOs (59,664 conditions). Read;
## not used yet (DialogueServer evaluates them with the speaker as subject and
## the listener as target).
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "ConditionSubrecord", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var conditions: Array[ConditionSubrecord] = []
## TCLT: the topics offered as choices after this INFO, on 6,348 INFOs. Read;
## not used yet.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "int", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var link_to_form_ids: Array[int] = []
## TCLF: the topics this INFO follows in a conversation, on 645 INFOs. Read;
## not used yet.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "int", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var link_from_form_ids: Array[int] = []
## TCFU: follow-up INFOs, on 1,107 INFOs. Read; used by DialogueServer: in a
## conversation, the first the speaker qualifies for is said after this one.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "int", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var follow_up_form_ids: Array[int] = []
## NAME: topics added to the player's topic list when this INFO is said, on
## 420 INFOs. Read; not used yet.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "int", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var add_topic_form_ids: Array[int] = []
## RNAM: the player's line that chooses this INFO, on 1,411 INFOs; empty when
## the topic's name is shown instead. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var prompt: String = ""
## ANAM: the NPC_ or CREA that says this INFO, on 11,355 INFOs; 0 when absent.
## Read; not used yet (only this actor may say it).
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var speaker_form_id: int = 0
## KNAM: the AVIF or PERK a speech challenge or perk choice tests, on 1,097
## INFOs. Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var actor_value_or_perk_form_id: int = 0
## DNAM: the speech challenge difficulty, on 3 INFOs. Read; not used yet.
@export_custom(PROPERTY_HINT_ENUM, "None,Very Easy,Easy,Average,Hard,Very Hard", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var speech_challenge: int = 0
## SCTX before NEXT: the Result Script (Begin), run as the INFO starts, on
## 2,827 INFOs. Read; not used yet.
@export_multiline var begin_script_source: String = ""
## SCTX after NEXT: the Result Script (End), run when the INFO finishes, on
## 4,544 INFOs. Read; not used yet.
@export_multiline var end_script_source: String = ""

## GetIsID's function index (CTDA).
const FUNCTION_GET_IS_ID := 72

## Runtime cache with no ESM source: see get_required_speaker(); -1 until
## worked out. Not saved.
var _required_speaker := -1

func has_flag(flag: int) -> bool:
	return (flags & flag) != 0

## The base FormID the speaker must be for this INFO's conditions to pass, or
## 0 when they allow any: a `GetIsID Base == 1` on the speaker (subject) that
## is in no OR group (a condition's OR flag joins it to the next). Worked out
## from `conditions` on first use; DialogueServer skips the INFO for any other
## speaker without evaluating its conditions.
func get_required_speaker() -> int:
	if _required_speaker == -1:
		_required_speaker = _find_required_speaker()
	return _required_speaker

func _find_required_speaker() -> int:
	for index in conditions.size():
		var condition := conditions[index]
		var joined_to_previous := index > 0 and conditions[index - 1].is_or()
		if condition.function_index != FUNCTION_GET_IS_ID or condition.is_or() or joined_to_previous:
			continue
		if condition.uses_global() or condition.run_on != ConditionSubrecord.RunOn.SUBJECT:
			continue
		if condition.comparison == ConditionSubrecord.Comparison.EQUAL and condition.comparison_value == 1.0:
			return condition.parameter_1
	return 0
