@tool
class_name ActorFacialPlayer
extends Node

## Sets the face's expression weights (Plans/Actors/faces.md). A child of the
## actor node (esm_actor_node.tscn), beside ActorHeadTracking; the actor node
## hands it the committed body (set_body).
##
## FaceGenServer delivers each face part with its TRI morphs as blend shapes
## named as in the TRI. This node keeps one weight per name and sets it on
## every face part with a blend shape of that name, so a blink closes the head's
## eyelids and the brows' together. Female heads name `MoodCocky` what the
## others name `Cocky`; both are the weight `Cocky`.
##
## Its inputs:
## - blinks, every `blink_delay_min` to `blink_delay_max` seconds, closing over
##   `blink_down_seconds` and opening over `blink_up_seconds`, none while
##   `LookDown` is above `look_down_disable_blinking`;
## - while the actor says a response (DialogueServer response_started to
##   line_finished), its TRDT emotion: the type is the morph name, the value
##   / 100 the weight, reached over `emotion_blend_seconds`.
## Defaults are the game settings the GECK lists (fBlinkDelayMin and the rest;
## not in FalloutNV.esm).

## Emotion morph names by DialogueResponseCollection.Emotion; Neutral has none.
const EMOTION_MORPHS := ["", "Anger", "Disgust", "Fear", "Sad", "Happy", "Surprise", "Pained"]
## Blend shape names read as another weight's name.
const MORPH_ALIASES := {"MoodCocky": "Cocky"}
const BLINK_MORPHS := ["BlinkLeft", "BlinkRight"]
const LOOK_DOWN_MORPH := "LookDown"

@export_group("Blinks")
## fBlinkDelayMin (GECK default 1.5 s).
@export var blink_delay_min := 1.5
## fBlinkDelayMax (GECK default 4.0 s).
@export var blink_delay_max := 4.0
## fBlinkDownTime (GECK default 0.04 s).
@export var blink_down_seconds := 0.04
## fBlinkUpTime (GECK default 0.14 s).
@export var blink_up_seconds := 0.14
## fLookDownDisableBlinkingAmt (GECK default 0.25).
@export var look_down_disable_blinking := 0.25

@export_group("Emotion")
## Seconds for a response's emotion to come in and to go out. No game setting
## is known for it.
@export var emotion_blend_seconds := 0.3

## Weight name -> Array of [MeshInstance3D, blend shape index].
var _targets := {}
## Weight name -> the weight last set on its targets.
var _applied := {}
## Seconds until the next blink starts.
var _blink_in := 0.0
## Seconds since the current blink started; negative while not blinking.
var _blink_elapsed := -1.0
## The morph of the emotion being shown, and its weight while the response lasts.
var _emotion_morph := ""
var _emotion_target := 0.0
var _emotion_weight := 0.0


func _enter_tree() -> void:
	if Engine.is_editor_hint():
		return
	if not DialogueServer.response_started.is_connected(_on_response_started):
		DialogueServer.response_started.connect(_on_response_started)
		DialogueServer.line_finished.connect(_on_line_finished)

func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	if DialogueServer.response_started.is_connected(_on_response_started):
		DialogueServer.response_started.disconnect(_on_response_started)
		DialogueServer.line_finished.disconnect(_on_line_finished)


## Finds every blend shape on `body`'s meshes and starts from a neutral face.
func set_body(body: Node3D) -> void:
	_targets.clear()
	_applied.clear()
	if body == null:
		return
	for child in body.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		var mesh := mesh_instance.mesh as ArrayMesh
		if mesh == null:
			continue
		for index in mesh.get_blend_shape_count():
			_add_target(_weight_name(String(mesh.get_blend_shape_name(index))), mesh_instance, index)
	_blink_in = _next_blink_delay()
	_blink_elapsed = -1.0
	set_process(not _targets.is_empty() and not Engine.is_editor_hint())


func _add_target(weight_name: String, mesh_instance: MeshInstance3D, index: int) -> void:
	if not _targets.has(weight_name):
		_targets[weight_name] = []
	_targets[weight_name].append([mesh_instance, index])


func _weight_name(morph_name: String) -> String:
	return MORPH_ALIASES.get(morph_name, morph_name)


## True when some face part has a blend shape for `weight_name`.
func has_weight(weight_name: String) -> bool:
	return _targets.has(_weight_name(weight_name))


## The weight last set for `weight_name`, 0 if none.
func get_weight(weight_name: String) -> float:
	return _applied.get(_weight_name(weight_name), 0.0)


## Sets `weight_name` on every face part that has it.
func set_weight(weight_name: String, weight: float) -> void:
	var name := _weight_name(weight_name)
	if _applied.get(name, 0.0) == weight:
		return
	_applied[name] = weight
	for target in _targets.get(name, []):
		var mesh_instance := target[0] as MeshInstance3D
		if is_instance_valid(mesh_instance):
			mesh_instance.set_blend_shape_value(target[1], weight)


func _process(delta: float) -> void:
	_update_blink(delta)
	_update_emotion(delta)


func _update_blink(delta: float) -> void:
	if _blink_elapsed < 0.0:
		_blink_in -= delta
		if _blink_in > 0.0:
			return
		_blink_in = _next_blink_delay()
		if get_weight(LOOK_DOWN_MORPH) > look_down_disable_blinking:
			return
		_blink_elapsed = 0.0
	_blink_elapsed += delta
	var weight := _blink_weight(_blink_elapsed)
	if _blink_elapsed >= blink_down_seconds + blink_up_seconds:
		_blink_elapsed = -1.0
		weight = 0.0
	for morph in BLINK_MORPHS:
		set_weight(morph, weight)


## The eyelids' weight `elapsed` seconds into a blink: closing, then opening.
func _blink_weight(elapsed: float) -> float:
	if elapsed < blink_down_seconds:
		return elapsed / blink_down_seconds
	return clampf(1.0 - (elapsed - blink_down_seconds) / blink_up_seconds, 0.0, 1.0)


func _next_blink_delay() -> float:
	return randf_range(blink_delay_min, blink_delay_max)


func _update_emotion(delta: float) -> void:
	if _emotion_morph.is_empty():
		return
	var step := delta / maxf(emotion_blend_seconds, 0.001)
	_emotion_weight = move_toward(_emotion_weight, _emotion_target, step)
	set_weight(_emotion_morph, _emotion_weight)
	if _emotion_weight == 0.0 and _emotion_target == 0.0:
		_emotion_morph = ""


## The actor started saying a response: shows its emotion.
func _on_response_started(line: DialogueLine, _text: String) -> void:
	if line.speaker == null or line.speaker != _actor():
		return
	var response := line.current_response()
	if response == null:
		return
	var morph: String = EMOTION_MORPHS[response.emotion]
	if morph != _emotion_morph:
		_clear_emotion_now()
	_emotion_morph = morph
	_emotion_target = response.emotion_value / 100.0
	if morph.is_empty():
		_emotion_target = 0.0


## The line ended: the emotion fades out.
func _on_line_finished(line: DialogueLine) -> void:
	if line.speaker == null or line.speaker != _actor():
		return
	_emotion_target = 0.0


func _clear_emotion_now() -> void:
	if not _emotion_morph.is_empty():
		set_weight(_emotion_morph, 0.0)
	_emotion_weight = 0.0


func _actor() -> EsmReference:
	var actor_node := get_parent() as EsmNode
	if actor_node == null:
		return null
	return actor_node.reference
