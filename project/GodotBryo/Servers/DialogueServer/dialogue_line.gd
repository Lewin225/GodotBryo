class_name DialogueLine
extends RefCounted

## One INFO being said: its speaker and listener, and how far through its
## responses it is. Runtime only; DialogueServer creates and advances it.

var info: DialogueInfoBase
var topic: DialogueTopicBase
var speaker: EsmReference
## Null for Say, which addresses no one.
var listener: EsmReference
## Each response's voice file path ("" for none), in order.
var voice_paths := PackedStringArray()
## Each response's voice, in order; null where there is none. Set when the
## line starts.
var streams: Array[AudioStream] = []
## Each response's duration in seconds, in order. Set when the line starts.
var durations := PackedFloat32Array()
## False while its voice files load; the line has not begun.
var started := false
## The response being said, an index into info.responses.
var response_index := 0
## Seconds the current response has been said.
var elapsed := 0.0
## Plays the current response's voice; freed when the line ends.
var voice_player: AudioStreamPlayer = null
## Filled by the loading task, read once it completes: path -> AudioStream or
## null.
var loaded: Dictionary = {}

func current_text() -> String:
	return info.responses[response_index].text if response_index < info.responses.size() else ""
