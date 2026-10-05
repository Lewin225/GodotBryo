class_name LowLevelTravel
extends Node

## Moves the actors NpcSimulationServer owns (LOW_LEVEL, no NpcController
## holding them) toward their `move_target`, along a route from
## NpcSimulationServer, writing their position and heading. The off-screen
## half of moving an actor; NpcController is the on-screen half.
##
## PackageRunner calls `advance()` for each actor on its turn in the unleased
## sweep, with the time since its last turn, so an actor's position is written
## once per sweep (README "Tick rates": position is the last tick's, not
## live). A route is derived state and never saved; it is computed on
## NpcSimulationServer's own thread (request_route) and applied on the main
## thread.

## Walk speed at SpeedMult 100, metres per second (NpcController's default).
@export var walk_speed := 1.6
## Run speed at SpeedMult 100, metres per second (NpcController's default),
## used while the actor's `move_running` is set.
@export var run_speed := 4.0
## Scales the speed: for tests, and the console's DebugSetLowLevelSpeed.
@export var speed_scale := 1.0
## A waypoint counts as reached within this distance, metres.
@export var arrive_radius := 0.3

## ActorReference -> its route: {"target": Vector3, "waypoints":
## PackedVector3Array, "index": int, "request_id": int}.
var _routes: Dictionary = {}
## Route request id -> the actor it is for.
var _actors_by_request: Dictionary = {}

func _ready() -> void:
	get_parent().route_ready.connect(_on_route_ready)

## Moves `actor` `elapsed` seconds along its route to move_target, while it is
## LOW_LEVEL; requests the route when the target changes.
func advance(actor: ActorReference, elapsed: float) -> void:
	if actor.simulation_mode != ActorReference.SimulationMode.LOW_LEVEL or not actor.has_move_target or actor.is_disabled():
		forget(actor)
		return
	var route: Dictionary = _routes.get(actor, {})
	if route.is_empty() or route["target"] != actor.move_target:
		forget(actor)
		var request_id: int = get_parent().request_route(actor.current_space_form_id, actor.position, actor.move_target)
		_routes[actor] = {"target": actor.move_target, "waypoints": PackedVector3Array(), "index": 0, "request_id": request_id}
		_actors_by_request[request_id] = actor
		return
	var waypoints: PackedVector3Array = route["waypoints"]
	var index: int = route["index"]
	if index >= waypoints.size():
		return
	var speed := run_speed if actor.move_running else walk_speed
	var budget := speed * _speed_mult(actor) / 100.0 * speed_scale * elapsed
	var position := actor.position
	while budget > 0.0 and index < waypoints.size():
		var to_next := waypoints[index] - position
		var distance := to_next.length()
		if distance <= budget:
			position = waypoints[index]
			budget -= distance
			index += 1
			continue
		position += to_next / distance * budget
		budget = 0.0
	route["index"] = index
	var heading := Vector2(position.x - actor.position.x, position.y - actor.position.y)
	if heading.length() > 0.001:
		# Authored heading about Gamebryo +Z, 0 facing +Y, turning clockwise.
		actor.rotation = Vector3(0.0, 0.0, atan2(heading.x, heading.y))
	actor.position = position
	if index >= waypoints.size() or position.distance_to(waypoints[waypoints.size() - 1]) <= arrive_radius:
		forget(actor)
		actor.reach_move_target()

## Drops `actor`'s route; a pending request's result is ignored.
func forget(actor: ActorReference) -> void:
	var route: Dictionary = _routes.get(actor, {})
	if not route.is_empty():
		_actors_by_request.erase(route["request_id"])
	_routes.erase(actor)

func _on_route_ready(request_id: int, result: Dictionary) -> void:
	var actor: ActorReference = _actors_by_request.get(request_id)
	_actors_by_request.erase(request_id)
	if actor == null or not _routes.has(actor):
		return
	var route: Dictionary = _routes[actor]
	if bool(result.get("found", false)):
		route["waypoints"] = result["waypoints"]
	else:
		push_warning("LowLevelTravel: no route for %s to %s" % [actor.instance_id, route["target"]])

func _speed_mult(actor: ActorReference) -> float:
	return actor.get_actor_values().get_current(ActorValue.SPEED_MULT)
