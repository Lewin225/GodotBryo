@tool
class_name DialogueTopicBase
extends EsmBase

## DIAL record: a dialogue topic and its INFO responses. FULL (`full_name`) is
## the topic's text in the player's topic list.

## DIAL and INFO DATA byte 0: the kind of topic.
enum Type { TOPIC, CONVERSATION, COMBAT, PERSUASION, DETECTION, SERVICE, MISCELLANEOUS, RADIO }

const FLAG_RUMORS := 0x01
const FLAG_TOP_LEVEL := 0x02

## QSTI: the quests adding INFOs to this topic, in authored order. Read; 138
## of 18,215 DIAL records in FalloutNV.esm name more than one. Not used yet;
## each INFO names its own quest.
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "int", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var quest_form_ids: Array[int] = []
## DATA byte 0. Read; not used yet (scripted speech and the conversation menu
## choose by topic, not type).
@export_custom(PROPERTY_HINT_ENUM, "Topic,Conversation,Combat,Persuasion,Detection,Service,Miscellaneous,Radio", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var topic_type: Type = Type.TOPIC
## DATA byte 1: flags, 0x01 Rumors (on 1 DIAL) and 0x02 Top-level (on 2,283);
## absent on 10 DIAL, read as 0. Read; not used yet (the topic list shows
## top-level topics first).
@export_custom(PROPERTY_HINT_FLAGS, "Rumors:1,Top-level:2", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var flags: int = 0
## PNAM: the topic's priority in the topic list; 50 on 17,230 DIAL, absent on
## 10, read as 50 (xEdit's default). Read; not used yet.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var priority: float = 50.0
## Not a DIAL field: the INFO records in this topic's child GRUP, in file
## order. 9,493 DIAL have INFOs, 8,722 none. Set from the record index; not
## used yet (DialogueServer chooses among them).
@export_custom(PROPERTY_HINT_ARRAY_TYPE, "DialogueInfoBase", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var infos: Array[DialogueInfoBase] = []

func is_top_level() -> bool:
	return (flags & FLAG_TOP_LEVEL) != 0
