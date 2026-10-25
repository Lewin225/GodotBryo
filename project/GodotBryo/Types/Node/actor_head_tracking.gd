@tool
class_name ActorHeadTracking
extends Node

## Which way the actor's head turns (Plans/Completed Plans/Actors/head_tracking.md). A child of
## the actor node (esm_actor_node.tscn), beside ActorAnimator and
## ActorEquipment. Owns the LookAtModifier3D on the skeleton's head bone; the
## actor node hands it the skeleton once the visual is built (set_skeleton).
##
## Every `evaluation_seconds` it chooses a target, the first rule that applies:
## 1. none, the modifier off so the head follows the animation, when the
##    active package has Head Tracking Off or the actor is not alive;
## 2. the actor's `look_target` (script Look, until StopLook);
## 3. the other side of the conversation it is in, unless its Dialogue package
##    has No Headtracking; or, while a line is being said (DialogueServer
##    response_started to line_finished), the listener for the speaker and the
##    speaker for the listener;
## 4. (combat, not built);
## 5. the nearest other head-tracked actor within `max_distance_units`
##    (times `interior_distance_mult` indoors), in front of the body (towards
##    the default aim point) and in line of sight,
##    held for `hold_seconds`; only while within `max_distance_from_player_units`
##    of the player.
## The player's body is an actor like any other: it chooses by the same rules,
## and others aim at its head bone.
## Distances are in Gamebryo units and default to the game settings the GECK
## lists (fAIMaxHeadTrackDistance and the rest; not in FalloutNV.esm). The head
## aims at the target's head bone when it has one, else its position plus
## `eye_height`; with no target, at `default_target_position` ahead of the body
## (carried with the hips, so seated it is ahead of the seated body). A line's
## look holds for `line_linger_seconds` after it ends.

## The modifier's node name under the skeleton.
const MODIFIER_NODE_NAME := "Look Target"
## The point the modifier aims at, a child of the skeleton.
const AIM_NODE_NAME := "Look Point"
## The bone the head turns on.
const HEAD_BONE_NAME := "Bip01 Head"
const UNITS_TO_METERS := 1.0 / 70.0

@export_group("Look At")
## Where the head looks when it tracks nothing, in the skeleton's space.
@export var default_target_position := Vector3(0.04669869, 1.0496129, 1.6604441)
## Seconds to turn to a new target.
@export var turn_duration := 1.0
## Offset of the look origin from the head bone; x nudges the eyeline down
## (too high and they stare at your feet).
@export var origin_offset := Vector3(0.15, 0.0, 0.0)
## How far the head may turn left and right, degrees: the whole range, half
## each way (100: 50 left, 50 right). The modifier's primary rotation, about
## the head bone's X axis, which points up.
@export var left_right_limit_degrees := 100.0
## How far the head may nod up and down, degrees: the whole range, half each
## way (90: 45 up, 45 down). The modifier's secondary rotation.
@export var up_down_limit_degrees := 90.0

@export_group("Choosing")
## How often the target is chosen again, seconds (OpenMW: 0.3).
@export var evaluation_seconds := 0.3
## fAIMaxHeadTrackDistance (GECK default 400 units).
@export var max_distance_units := 400.0
## fAIInteriorHeadTrackMult (GECK default 0.5).
@export var interior_distance_mult := 0.5
## fAIMaxHeadTrackDistanceFromPC (GECK default 2000 units): actors further
## from the player do not choose a default target.
@export var max_distance_from_player_units := 2000.0
## fAIHoldDefaultHeadTrackTimer (GECK default 10 s): how long a default target
## is kept before choosing again.
@export var hold_seconds := 10.0
## Height of the eyes above a target without a skeleton, metres.
@export var eye_height := 1.6
## After a line ends, how long speaker and listener keep looking at each
## other, seconds, in case another line follows.
@export var line_linger_seconds := 3.0

## Every ActorHeadTracking in the tree: the candidates for the default target.
static var _instances: Array[ActorHeadTracking] = []

var _modifier: LookAtModifier3D = null
var _aim: Node3D = null
var _skeleton: Skeleton3D = null
var _target: EsmReference = null
var _default_target: EsmReference = null
var _default_held_until_msec := 0
var _evaluate_in := 0.0
## The other side of the line being said, or last said, that involves this
## actor, or null.
var _line_partner: EsmReference = null
## Whether that line is still being said.
var _line_active := false
## When a finished line stops holding the look (Time.get_ticks_msec()).
var _line_partner_until_msec := 0

func _enter_tree() -> void:
	if not _instances.has(self):
		_instances.append(self)
	if Engine.is_editor_hint():
		return
	if not DialogueServer.response_started.is_connected(_on_response_started):
		DialogueServer.response_started.connect(_on_response_started)
		DialogueServer.line_finished.connect(_on_line_finished)

func _exit_tree() -> void:
	_instances.erase(self)
	if Engine.is_editor_hint():
		return
	if DialogueServer.response_started.is_connected(_on_response_started):
		DialogueServer.response_started.disconnect(_on_response_started)
		DialogueServer.line_finished.disconnect(_on_line_finished)

func _on_response_started(line: DialogueLine, _text: String) -> void:
	var actor := _actor()
	if actor == null or line.speaker == null or line.listener == null:
		return
	if line.speaker == actor:
		_line_partner = line.listener
	elif line.listener == actor:
		_line_partner = line.speaker
	else:
		return
	_line_active = true
	_evaluate_in = 0.0

## The line ended: the look holds for line_linger_seconds, in case another
## follows.
func _on_line_finished(line: DialogueLine) -> void:
	if _line_partner != null and (line.speaker == _line_partner or line.listener == _line_partner):
		_line_active = false
		_line_partner_until_msec = Time.get_ticks_msec() + int(line_linger_seconds * 1000.0)

## Adds the look-at modifier to `skeleton`'s head bone, once per skeleton.
func set_skeleton(skeleton: Skeleton3D) -> void:
	if skeleton == null:
		return
	_skeleton = skeleton
	var existing := skeleton.get_node_or_null(NodePath(MODIFIER_NODE_NAME)) as LookAtModifier3D
	if existing != null:
		_modifier = existing
		_aim = skeleton.get_node_or_null(NodePath(AIM_NODE_NAME)) as Node3D
		return
	if skeleton.find_bone(HEAD_BONE_NAME) == -1:
		EsmActorNode._warn_once("ActorHeadTracking: skeleton has no %s bone" % HEAD_BONE_NAME)
		return
	var aim := Marker3D.new()
	aim.name = AIM_NODE_NAME
	aim.position = default_target_position
	skeleton.add_child(aim)
	_aim = aim
	var modifier := LookAtModifier3D.new()
	modifier.name = MODIFIER_NODE_NAME
	modifier.bone_name = HEAD_BONE_NAME
	modifier.duration = turn_duration
	modifier.transition_type = Tween.TRANS_SINE
	modifier.ease_type = Tween.EASE_IN_OUT
	modifier.forward_axis = SkeletonModifier3D.BONE_AXIS_PLUS_Y
	modifier.primary_rotation_axis = Vector3.AXIS_X
	modifier.origin_offset = origin_offset
	modifier.origin_safe_margin = 10.0
	modifier.use_angle_limitation = true
	modifier.symmetry_limitation = true
	# LookAtModifier3D's limits are radians, the whole range when symmetric
	# (look_at_modifier_3d.cpp halves them).
	modifier.primary_limit_angle = deg_to_rad(left_right_limit_degrees)
	modifier.secondary_limit_angle = deg_to_rad(up_down_limit_degrees)
	skeleton.add_child(modifier)
	modifier.target_node = modifier.get_path_to(aim)
	_modifier = modifier

## The look-at modifier on the current skeleton, or null before one is set.
func get_modifier() -> LookAtModifier3D:
	return _modifier if is_instance_valid(_modifier) else null

## What the head is turned to now, or null (straight ahead, or off).
func get_target() -> EsmReference:
	return _target

## Where this actor's eyes are, in the world: its head bone, else the actor
## node plus eye_height. For other actors aiming at it.
func get_eye_position() -> Vector3:
	if is_instance_valid(_skeleton):
		var bone := _skeleton.find_bone(HEAD_BONE_NAME)
		if bone != -1:
			return (_skeleton.global_transform * _skeleton.get_bone_global_pose(bone)).origin
	var actor_node := get_parent() as Node3D
	return actor_node.global_position + Vector3.UP * eye_height if actor_node != null else Vector3.ZERO

func _process(delta: float) -> void:
	if Engine.is_editor_hint() or get_modifier() == null or not is_instance_valid(_aim):
		return
	_evaluate_in -= delta
	if _evaluate_in <= 0.0:
		_evaluate_in = evaluation_seconds
		_choose()
	_aim_at_target()

## Applies the rules (see the class description) to choose `_target`.
func _choose() -> void:
	var actor := _actor()
	if actor == null:
		_set_tracking(false, null)
		return
	if not actor.alive or _package_has_head_tracking_off(actor):
		_set_tracking(false, null)
		return
	if actor.look_target != null:
		_set_tracking(true, actor.look_target)
		return
	var partner := _conversation_partner(actor)
	if partner == null:
		partner = _current_line_partner()
	if partner != null:
		_set_tracking(true, partner)
		return
	_set_tracking(true, _choose_default(actor))

## The partner of a line being said, or said less than line_linger_seconds ago.
func _current_line_partner() -> EsmReference:
	if _line_partner == null:
		return null
	if _line_active or Time.get_ticks_msec() < _line_partner_until_msec:
		return _line_partner
	_line_partner = null
	return null

func _set_tracking(enabled: bool, target: EsmReference) -> void:
	_modifier.active = enabled
	_target = target

## The other side of the conversation `actor` is in, unless the speaker's
## active package is a Dialogue package with No Headtracking.
func _conversation_partner(actor: ActorReference) -> EsmReference:
	var speaker := DialogueServer.get_conversation_speaker()
	var listener := DialogueServer.get_conversation_listener()
	if speaker == null or listener == null:
		return null
	var speaker_actor := speaker as ActorReference
	if speaker_actor != null and speaker_actor.active_package != null:
		var package := speaker_actor.active_package
		if package.package_type == PackageBase.PackageType.DIALOGUE and (package.dialogue_flags & PackageBase.DIALOGUE_FLAG_NO_HEADTRACKING) != 0:
			return null
	if actor == speaker:
		return listener
	if actor == listener:
		return speaker
	return null

## Rule 5: the nearest other head-tracked actor in range, in front and in line
## of sight, kept for hold_seconds while it stays so.
func _choose_default(actor: ActorReference) -> EsmReference:
	var player := ScriptServer.player_reference
	if player != null and player != actor and _distance_units(actor, player) > max_distance_from_player_units:
		return null
	var range_units := max_distance_units * (interior_distance_mult if _is_interior(actor) else 1.0)
	if _default_target != null and Time.get_ticks_msec() < _default_held_until_msec and _qualifies(actor, _default_target, range_units):
		return _default_target
	var best: EsmReference = null
	var best_distance := INF
	for other_tracking in _instances:
		var other := other_tracking._actor()
		if other == null or other == actor or other_tracking == self:
			continue
		var distance := _distance_units(actor, other)
		if distance >= best_distance or not _qualifies(actor, other, range_units):
			continue
		best = other
		best_distance = distance
	_default_target = best
	_default_held_until_msec = Time.get_ticks_msec() + int(hold_seconds * 1000.0)
	return best

## In range, in front (positive dot product with the facing) and in line of
## sight from this head to the other's eyes.
func _qualifies(actor: ActorReference, other: EsmReference, range_units: float) -> bool:
	if other.current_space_form_id != actor.current_space_form_id or other.is_disabled():
		return false
	if _distance_units(actor, other) > range_units:
		return false
	var head := get_eye_position()
	var eyes := _eye_position_of(other)
	# Where the body faces: towards the default aim point, which turns with it
	# (seated, away from the controller's facing).
	var facing := _default_aim_position() - head
	var to_other := eyes - head
	if Vector2(facing.x, facing.z).dot(Vector2(to_other.x, to_other.z)) <= 0.0:
		return false
	var query := PhysicsRayQueryParameters3D.create(head, eyes, 1)
	var hit := (get_parent() as Node3D).get_world_3d().direct_space_state.intersect_ray(query)
	return hit.is_empty()

func _aim_at_target() -> void:
	if _target == null:
		_aim.global_position = _default_aim_position()
		return
	_aim.global_position = _eye_position_of(_target)

## Where the head looks when it tracks nothing: default_target_position,
## carried with the body by how far the hips (Bip01 NonAccum) have moved and
## turned from their rest pose, so a seated actor (its body turned within the
## skeleton by the furniture idles) looks ahead of its body, not behind it.
func _default_aim_position() -> Vector3:
	return _body_frame() * default_target_position

## The skeleton's frame moved with the hips' displacement from rest.
func _body_frame() -> Transform3D:
	var hips := _skeleton.find_bone("Bip01 NonAccum")
	if hips == -1:
		return _skeleton.global_transform
	return _skeleton.global_transform * _skeleton.get_bone_global_pose(hips) * _skeleton.get_bone_global_rest(hips).affine_inverse()

## Where `reference`'s eyes are: its ActorHeadTracking's head bone when it has
## one in the tree, else its position plus eye_height.
func _eye_position_of(reference: EsmReference) -> Vector3:
	for other_tracking in _instances:
		if other_tracking._actor() == reference:
			return other_tracking.get_eye_position()
	return EsmReferencePhysicaliser.GAMEBRYO_TO_GODOT_BASIS * reference.position + Vector3.UP * eye_height

func _actor() -> ActorReference:
	var actor_node := get_parent() as EsmActorNode
	return actor_node.reference as ActorReference if actor_node != null else null

static func _package_has_head_tracking_off(actor: ActorReference) -> bool:
	return actor.active_package != null and (actor.active_package.general_flags & PackageBase.GENERAL_FLAG_HEAD_TRACKING_OFF) != 0

## Indoors: an interior CELL is its own space.
static func _is_interior(actor: ActorReference) -> bool:
	return actor.current_cell_form_id != 0 and actor.current_cell_form_id == actor.current_space_form_id

static func _distance_units(a: EsmReference, b: EsmReference) -> float:
	return a.position.distance_to(b.position) / UNITS_TO_METERS
