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
## Each response's lip animation, in order; null where there is none. Set
## when the line starts.
var lips: Array[LipReader] = []
## False while its voice files load; the line has not begun.
var started := false
## The response being said, an index into info.responses.
var response_index := 0
## Seconds the current response has been said.
var elapsed := 0.0
## Plays the current response's voice at the speaker (DialogueServer places
## it each frame); freed when the line ends.
var voice_player: AudioStreamPlayer3D = null
## Filled by the loading task, read once it completes: path -> AudioStream or
## null.
var loaded: Dictionary = {}
## Filled by the loading task as `loaded` is: voice file path -> LipReader or
## null.
var loaded_lips: Dictionary = {}

## The response being said, or null after the last.
func current_response() -> DialogueResponseCollection:
	return info.responses[response_index] if response_index < info.responses.size() else null

## Seconds into the current response's voice as heard: the voice player's
## playback position, 0 until it starts playing, or `elapsed` for a response
## with no voice.
func voice_seconds() -> float:
	var has_voice := response_index < streams.size() and streams[response_index] != null
	if not has_voice or voice_player == null:
		return elapsed
	if not voice_player.playing:
		return 0.0
	return voice_player.get_playback_position() + AudioServer.get_time_since_last_mix()

## The current response's lip animation, or null.
func current_lip() -> LipReader:
	return lips[response_index] if response_index < lips.size() else null

func current_text() -> String:
	return info.responses[response_index].text if response_index < info.responses.size() else ""
