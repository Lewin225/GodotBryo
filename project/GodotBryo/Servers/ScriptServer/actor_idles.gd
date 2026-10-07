class_name ActorIdles
extends Node

## Plays the idles scripts and package events ask actors to play (PlayIdle, a
## package's On Begin / End / Change idle), for any actor, on screen or off. A
## child of ScriptServer, beside FurnitureSeating.
##
## The idle is the actor's state (ActorReference.special_idle); the actor
## node's ActorAnimator plays it in place of locomotion, its StartLoop - EndLoop
## section the IDLE's loop count of times (forever for 255, until something
## replaces or finishes it), and when it ends the actor returns to locomotion, turned the way the idle left its
## body (as standing up from furniture does). An actor whose animations are
## still loading keeps the idle and plays it once they load (EsmActorNode). An
## actor without a built visual ends the idle at once: nothing sees it
## (Plans/Actors/stage_f.md, Open). A seated actor does not play it: the
## furniture idles own its body.

## `actor` plays `idle`, replacing any idle asked for before.
func play(actor: ActorReference, idle: IdleBase) -> void:
	if actor == null or idle == null or actor.sit_state != FurnitureSeating.NOT_SITTING:
		return
	actor.special_idle = idle
	var animator := FurnitureSeating._animator_for(actor)
	if animator == null:
		actor.special_idle = null
		return
	if not animator.is_loaded():
		return
	animator.idle_finished.connect(_on_finished.bind(actor, animator, idle), CONNECT_ONE_SHOT)
	animator.play_idle(idle)

## `actor`'s idle has ended: it returns to locomotion.
func finish(actor: ActorReference) -> void:
	actor.special_idle = null
	var animator := FurnitureSeating._animator_for(actor)
	if animator == null or animator.get_idle() == null:
		return
	var turn := animator.stop_idle()
	var body := FurnitureSeating._body_for(actor)
	if body != null:
		body.rotation.y -= turn
		actor.rotation = EsmReferencePhysicaliser.authored_heading(body.rotation.y)

func _on_finished(_finished: IdleBase, actor: ActorReference, _animator: ActorAnimator, idle: IdleBase) -> void:
	# A later idle replaced this one; that one finishes it.
	if actor.special_idle != idle:
		return
	finish(actor)
