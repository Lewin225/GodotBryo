class_name DialogueLine
extends RefCounted

## One INFO being said: its speaker and listener, and how far through its
## responses it is. Runtime only; DialogueServer creates and advances it.

var info: DialogueInfoBase
var topic: DialogueTopicBase
var speaker: EsmReference
## Null for Say, which addresses no one.
var listener: EsmReference
## The response being said, an index into info.responses.
var response_index := 0
## Seconds the current response has been said.
var elapsed := 0.0
## Each response's duration in seconds, in order.
var durations := PackedFloat32Array()

func current_text() -> String:
	return info.responses[response_index].text if response_index < info.responses.size() else ""
