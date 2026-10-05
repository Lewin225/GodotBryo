class_name LowLevelTravel
extends Node

## Moves the actors NpcSimulationServer owns (LOW_LEVEL, no NpcController
## holding them) toward their `move_target`, along a route from
## NpcSimulationServer, writing their position and heading every physics
## frame. The off-screen half of moving an actor; NpcController is the
## on-screen half. Only actors handed to `track()` move (those running a
## package); a route is derived state and never saved.
##
## Runs on the main thread: it writes Resources. Routes are computed on worker
## threads by NpcSimulationServer.request_route and only applied here.

## Walk speed at SpeedMult 100, metres per second (NpcController's default).
@export var walk_speed := 1.6
## Run speed at SpeedMult 100, metres per second (NpcController's default),
## used while the actor's `move_running` is set.
@export var run_speed := 4.0
## Scales the speed, for tests.
@export var speed_scale := 1.0
## A waypoint counts as reached within this distance, metres.
@export var arrive_radius := 0.3

## ActorReference -> its route: {"target": Vector3, "waypoints":
## PackedVector3Array, "index": int, "request_id": int}.
var _routes: Dictionary = {}

func _ready() -> void:
	var server := get_parent()
	server.route_ready.connect(_on_route_ready)

## Moves `actor` toward its move_target while it is LOW_LEVEL.
func track(actor: ActorReference) -> void:
	if not _routes.has(actor):
		_routes[actor] = _empty_route()

func untrack(actor: ActorReference) -> void:
	_routes.erase(actor)

func is_tracked(actor: ActorReference) -> bool:
	return _routes.has(actor)

func _physics_process(delta: float) -> void:
	for actor: ActorReference in _routes.keys():
		_travel(actor, delta)

func _travel(actor: ActorReference, delta: float) -> void:
	var route: Dictionary = _routes[actor]
	if actor.simulation_mode != ActorReference.SimulationMode.LOW_LEVEL or not actor.has_move_target or actor.is_disabled():
		_routes[actor] = _empty_route()
		return
	if route["target"] != actor.move_target:
		route = _empty_route()
		route["target"] = actor.move_target
		route["request_id"] = get_parent().request_route(actor.current_space_form_id, actor.position, actor.move_target)
		_routes[actor] = route
		return
	var waypoints: PackedVector3Array = route["waypoints"]
	var index: int = route["index"]
	if index >= waypoints.size():
		return
	var speed := run_speed if actor.move_running else walk_speed
	var budget := speed * _speed_mult(actor) / 100.0 * speed_scale * delta
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
		_routes[actor] = _empty_route()
		actor.reach_move_target()

func _on_route_ready(request_id: int, result: Dictionary) -> void:
	for actor: ActorReference in _routes.keys():
		var route: Dictionary = _routes[actor]
		if route["request_id"] != request_id:
			continue
		route["request_id"] = -1
		if bool(result.get("found", false)):
			route["waypoints"] = result["waypoints"]
		else:
			push_warning("LowLevelTravel: no route for %s to %s" % [actor.instance_id, route["target"]])
		return

func _speed_mult(actor: ActorReference) -> float:
	return actor.get_actor_values().get_current(ActorValue.SPEED_MULT)

func _empty_route() -> Dictionary:
	return {"target": Vector3.INF, "waypoints": PackedVector3Array(), "index": 0, "request_id": -1}
