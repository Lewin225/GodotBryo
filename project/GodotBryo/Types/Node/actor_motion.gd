class_name ActorMotion
extends RefCounted

## How a controller is moving its actor, for the actor node's animator to
## choose clips from. A controller (PlayerController, NpcController) creates
## one, hands it to its EsmActorNode once (`EsmActorNode.motion`) and updates
## the fields in place every physics frame. Runtime only, never saved.
##
## Every vector is in the actor's local Godot axes: forward is -Z, right is
## +X, up is +Y. Weapon stance, crippled limbs and health are not here: the
## animator reads those from the actor itself.

## The direction the controller wants to move in, x right and y forward,
## length 0-1. Leads `velocity` when starting and stopping.
var move_input := Vector2.ZERO
## The actor's current velocity, metres per second.
var velocity := Vector3.ZERO
## How fast the actor is turning about up, radians per second; positive turns
## left (counter-clockwise seen from above).
var turn_rate := 0.0
## Whether the actor stands on the ground.
var grounded := true
## Whether the actor moves at run rather than walk pace.
var running := false
## Whether the actor is sneaking.
var sneaking := false

## Speed across the ground, metres per second.
func get_planar_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()
