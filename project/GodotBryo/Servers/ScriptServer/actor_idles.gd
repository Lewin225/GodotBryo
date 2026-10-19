class_name ActorIdles
extends Node

## Plays the idles actors are asked to play, for any actor, on screen or off:
## PlayIdle and PickIdle, a package's On Begin / End / Change idle, its idle
## collection, ambient idles from the idle tree, and dialogue gestures on each
## response said or heard (Plans/Completed Plans/Actors/stage_f.md).
## A child of ScriptServer, beside FurnitureSeating.
##
## The idle is the actor's state (ActorReference.special_idle); the actor
## node's ActorAnimator plays it in place of locomotion, its StartLoop - EndLoop
## section the IDLE's loop count of times (forever for 255, until something
## replaces or finishes it), and when it ends the actor returns to locomotion,
## facing as it did. An actor whose animations are
## still loading keeps the idle and plays it once they load (EsmActorNode). An
## actor without a built visual ends the idle at once: nothing sees it
## (Plans/Completed Plans/Actors/stage_f.md, Open). A seated actor does not play it: the
## furniture idles own its body.

## Seconds between a collection's idles when its IDLT is 0: GECK's default for
## fAIIdleWaitTime, which FalloutNV.esm does not set (meaning inferred from the
## name).
const DEFAULT_IDLE_WAIT_SECONDS := 1.0
## How far from the player an actor plays its package's idle collection,
## metres: GECK's default for fAIIdleAnimationDistance, 2000 units, which
## FalloutNV.esm does not set (meaning inferred from the name).
const IDLE_ANIMATION_DISTANCE := 2000.0 / 70.0

## Seconds between an actor's ambient idles at energy level 50 (NPC_ AIDT),
## scaled by energy / 50 and at least DEFAULT_IDLE_WAIT_SECONDS. The GECK says
## lower energy idles more often; the formula has no source.
@export var ambient_idle_seconds := 20.0

## Actor -> the dialogue gesture it is playing for the line said or heard.
var _dialogue_idles: Dictionary = {}
## Actor -> Time.get_ticks_msec() of its next ambient pick.
var _ambient_next_msec: Dictionary = {}
## Actor -> {"package", "next_msec", "index", "done"}: where it is in its
## package's idle collection.
var _collections: Dictionary = {}
## Actor -> {IdleBase: Time.get_ticks_msec() when it last started}, for
## Replay Delay.
var _last_played: Dictionary = {}

func _ready() -> void:
	# DialogueServer is an autoload that may be added after ScriptServer.
	_connect_dialogue.call_deferred()

func _connect_dialogue() -> void:
	DialogueServer.response_started.connect(_on_response_started)
	DialogueServer.line_finished.connect(_on_line_finished)

## `actor` plays `idle`, replacing any idle asked for before.
func play(actor: ActorReference, idle: IdleBase) -> void:
	if actor == null or idle == null or actor.sit_state != FurnitureSeating.NOT_SITTING:
		return
	actor.special_idle = idle
	actor.last_idle = idle
	var animator := FurnitureSeating._animator_for(actor)
	if animator == null:
		actor.special_idle = null
		return
	if not animator.is_loaded():
		return
	# One connection per animator: Godot counts connections to one method as the
	# same callable whatever is bound, so a connection per idle would be refused
	# while an earlier one (an idle replaced before it finished) remains.
	var on_finished := Callable(self, "_on_idle_finished").bind(animator)
	if not animator.idle_finished.is_connected(on_finished):
		animator.idle_finished.connect(on_finished)
	animator.play_idle(idle)

## `actor`'s idle has ended: it returns to locomotion, facing as it did. (Only
## standing up from furniture turns the actor, FurnitureSeating; a gesture's
## torso yaw against locomotion's is the clips' frame, not a turn.)
func finish(actor: ActorReference) -> void:
	actor.special_idle = null
	var animator := FurnitureSeating._animator_for(actor)
	if animator == null or animator.get_idle() == null:
		return
	animator.stop_idle()

## An actor standing idle with a 3D node (NpcController, each physics frame),
## within IDLE_ANIMATION_DISTANCE of the player and while no idle plays: its
## package's idle collection when it has one, else an ambient pick from the
## idle tree (update_ambient).
func update_standing(actor: ActorReference) -> void:
	var package := actor.active_package
	if package != null and not package.idle_animations.is_empty():
		_ambient_next_msec.erase(actor)
		update_collection(actor)
		return
	_collections.erase(actor)
	update_ambient(actor)

## Ambient idles: every ambient_seconds(actor) after the last idle ended, the
## actor plays the Idle Manager's pick for it (IdleTree.pick_for), when that is
## an idle with a KF whose Replay Delay has run out.
func update_ambient(actor: ActorReference) -> void:
	var now := Time.get_ticks_msec()
	var wait := int(ambient_seconds(actor) * 1000.0)
	if actor.special_idle != null or actor.has_move_target or not _ambient_next_msec.has(actor):
		_ambient_next_msec[actor] = now + wait
		return
	if now < int(_ambient_next_msec[actor]) or not _near_player(actor):
		return
	_ambient_next_msec[actor] = now + wait
	var idle := ScriptServer.idle_tree.pick_for(actor)
	if idle == null or not idle.has_kf() or not _replay_delay_passed(actor, idle):
		return
	_mark_played(actor, idle)
	play(actor, idle)

## Seconds between `actor`'s ambient idles: ambient_idle_seconds scaled by its
## energy level (NPC_ AIDT, from its AI Data template) over 50.
func ambient_seconds(actor: ActorReference) -> float:
	var base := ActorBase.template_source(actor.base, ActorBase.TEMPLATE_USE_AI_DATA)
	var energy := base.energy if base != null else 50
	return maxf(DEFAULT_IDLE_WAIT_SECONDS, ambient_idle_seconds * energy / 50.0)

## PickIdle: `actor` plays the Idle Manager's pick for it now. Returns the
## idle, or null when none qualifies or it has no KF.
func pick_and_play(actor: ActorReference) -> IdleBase:
	var idle := ScriptServer.idle_tree.pick_for(actor)
	if idle == null or not idle.has_kf():
		return null
	_mark_played(actor, idle)
	play(actor, idle)
	return idle

## A package's idle collection (PACK IDLA): plays one of its idles
## IDLT seconds after the last ended (DEFAULT_IDLE_WAIT_SECONDS when 0), within
## IDLE_ANIMATION_DISTANCE of the player and while no idle plays. The idle's
## conditions must pass (the actor as subject) and its Replay Delay since it
## last played must have passed. Run In Sequence picks in list order, else at
## random; Do Once stops after one pass through the list (Plans/Actors/
## stage_f.md: the bit names and IDLT's meaning are inferred).
func update_collection(actor: ActorReference) -> void:
	var package := actor.active_package
	if package == null or package.idle_animations.is_empty():
		_collections.erase(actor)
		return
	var state: Dictionary = _collections.get(actor, {})
	var now := Time.get_ticks_msec()
	if state.get("package") != package:
		state = {"package": package, "next_msec": now + _wait_msec(package), "index": 0, "done": false}
		_collections[actor] = state
	# IDLT is the gap between idles: it counts from when the last one ended.
	if actor.special_idle != null or actor.has_move_target:
		state["next_msec"] = now + _wait_msec(package)
		return
	if bool(state["done"]) or now < int(state["next_msec"]):
		return
	if not _near_player(actor):
		return
	state["next_msec"] = now + _wait_msec(package)
	var idle := _pick_from_collection(actor, package, state)
	if idle == null:
		return
	_mark_played(actor, idle)
	play(actor, idle)

## The collection's next idle that may play now, or null: in order from
## state["index"] for Run In Sequence (Do Once marks the state done after the
## last), else a random one of those that may.
func _pick_from_collection(actor: ActorReference, package: PackageBase, state: Dictionary) -> IdleBase:
	var idles := package.idle_animations
	if (package.idle_collection_flags & PackageBase.IDLE_COLLECTION_FLAG_RUN_IN_SEQUENCE) != 0:
		var index := int(state["index"])
		for offset in idles.size():
			var candidate := idles[(index + offset) % idles.size()]
			if not _may_play(actor, candidate):
				continue
			var next := index + offset + 1
			state["index"] = next % idles.size()
			if next >= idles.size() and (package.idle_collection_flags & PackageBase.IDLE_COLLECTION_FLAG_DO_ONCE) != 0:
				state["done"] = true
			return candidate
		return null
	var allowed: Array[IdleBase] = []
	for candidate in idles:
		if _may_play(actor, candidate):
			allowed.append(candidate)
	if allowed.is_empty():
		return null
	var picked := allowed[randi() % allowed.size()]
	if (package.idle_collection_flags & PackageBase.IDLE_COLLECTION_FLAG_DO_ONCE) != 0:
		state["done"] = true
	return picked

## Whether `idle` may play on `actor` now: it has a KF, its conditions pass and
## its Replay Delay has passed since it last started.
func _may_play(actor: ActorReference, idle: IdleBase) -> bool:
	if idle == null or not idle.has_kf() or not _replay_delay_passed(actor, idle):
		return false
	return ScriptServer.evaluate_conditions(idle.conditions, ConditionContext.new(actor))

## Whether `idle`'s Replay Delay has run out since it last started on `actor`.
func _replay_delay_passed(actor: ActorReference, idle: IdleBase) -> bool:
	var started := int((_last_played.get(actor, {}) as Dictionary).get(idle, -1))
	return started < 0 or Time.get_ticks_msec() - started >= idle.replay_delay * 1000

func _mark_played(actor: ActorReference, idle: IdleBase) -> void:
	if not _last_played.has(actor):
		_last_played[actor] = {}
	_last_played[actor][idle] = Time.get_ticks_msec()

func _wait_msec(package: PackageBase) -> int:
	var seconds := package.idle_timer if package.idle_timer > 0.0 else DEFAULT_IDLE_WAIT_SECONDS
	return int(seconds * 1000.0)

## Whether `actor` is in the player's space within IDLE_ANIMATION_DISTANCE.
func _near_player(actor: ActorReference) -> bool:
	var player := ScriptServer.player_reference
	if player == null or player.current_space_form_id != actor.current_space_form_id:
		return false
	return player.position.distance_to(actor.position) <= IDLE_ANIMATION_DISTANCE

## Dialogue gestures: on each response (a "conversation item", GECK "Idle
## Animations"), the speaker plays the response's speaker idle (INFO SNAM)
## and the listener its listener idle (LNAM) when it names one, else each its
## Idle Manager pick, which the idle tree's DialogueIdles serves while they
## talk (GetCurrentAIProcedure DIALOGUE, IsTalking, GetDialogueEmotion,
## IsLastIdlePlayed). Any actor, the player's body included.
func _on_response_started(line: DialogueLine, _text: String) -> void:
	var response := line.current_response()
	if response == null:
		return
	_play_dialogue_idle(line.speaker as ActorReference, response.speaker_idle_form_id)
	_play_dialogue_idle(line.listener as ActorReference, response.listener_idle_form_id)

## Plays the named idle (a FormID, 0 for none) or the actor's pick, when it
## has a KF and its Replay Delay has run out.
func _play_dialogue_idle(actor: ActorReference, named_form_id: int) -> void:
	if actor == null:
		return
	var idle: IdleBase = null
	if named_form_id != 0:
		idle = EsmServer.get_base(named_form_id) as IdleBase
	else:
		idle = ScriptServer.idle_tree.pick_for(actor)
	if idle == null or not idle.has_kf() or not _replay_delay_passed(actor, idle):
		return
	_mark_played(actor, idle)
	play(actor, idle)
	if actor.special_idle == idle:
		_dialogue_idles[actor] = idle

## A line ended: a dialogue gesture its speaker or listener still plays (one
## that loops) ends with it.
func _on_line_finished(line: DialogueLine) -> void:
	for reference in [line.speaker, line.listener]:
		var actor := reference as ActorReference
		if actor == null or not _dialogue_idles.has(actor):
			continue
		if actor.special_idle == _dialogue_idles[actor]:
			finish(actor)
		_dialogue_idles.erase(actor)

## An idle ended on `animator`: the actor returns to locomotion if it is the
## idle it was asked to play (not a furniture idle, nor one since replaced).
func _on_idle_finished(finished: IdleBase, animator: ActorAnimator) -> void:
	var actor_node := animator.get_parent() as EsmActorNode
	var actor := actor_node.reference as ActorReference if actor_node != null else null
	if actor == null or finished == null or actor.special_idle != finished:
		return
	finish(actor)
