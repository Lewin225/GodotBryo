class_name DialogueChoice
extends RefCounted

## One choice the player is offered in a conversation: a topic, the INFO the
## speaker would say for it, and the text shown. Runtime only.

var topic: DialogueTopicBase
## The INFO the speaker says when this is chosen.
var info: DialogueInfoBase
## The INFO's prompt (RNAM), or the topic's name (FULL) when it has none.
var text := ""
