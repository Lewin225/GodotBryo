class_name NpcController
extends Node3D

## Moves a physicalised NPC or creature: the cheaper sibling of
## PlayerController (npc_controller.tscn). NpcSimulationServer decides where
## the actor goes (`ActorReference.move_target`) and routes it; this follows
## the route's waypoints one hop at a time with its NavigationAgent3D on the
## space's local navigation map, which adds avoidance between agents. Movement
## is kinematic: the navmesh says where an actor can walk, so there is no
## move_and_slide. The Body capsule is what trigger volumes and the player
## collide with.
##
## While the reference is PHYSICAL_LEASED this writes its position and heading
## every physics frame and publishes an ActorMotion to the EsmActorNode child,
## which renders the actor and chooses its clips.

## Walk speed at SpeedMult 100, metres per second.
@export var walk_speed := 1.6
## Run speed at SpeedMult 100, metres per second.
@export var run_speed := 4.0
## Scales both speeds, to tune against the original game by eye.
@export var speed_scale := 1.0
## Whether the actor runs rather than walks. Packages will set it.
@export var running := false
## How fast the actor turns toward where it moves, degrees per second.
@export var turn_speed_degrees := 360.0
## A waypoint counts as reached within this distance across the ground,
## metres.
@export var arrive_radius := 0.3
## When the way ahead is more than this many degrees off the actor's facing,
## it turns on the spot before moving.
@export var turn_in_place_degrees := 45.0

## The actor this controller moves. Assigning it places the controller and
## hands the reference to the EsmActorNode child.
var reference: ActorReference:
	set(value):
		if reference == value:
			return
		_disconnect_reference()
		reference = value
		if is_inside_tree():
			_apply_reference()

## How this controller moves its actor, handed to the EsmActorNode once and
## updated in place.
var motion := ActorMotion.new()

var actor: EsmActorNode:
	get:
		return get_node_or_null(^"EsmActorNode") as EsmActorNode
var agent: NavigationAgent3D:
	get:
		return get_node_or_null(^"NavigationAgent3D") as NavigationAgent3D
var body: AnimatableBody3D:
	get:
		return get_node_or_null(^"Body") as AnimatableBody3D
var ground_ray: RayCast3D:
	get:
		return get_node_or_null(^"GroundRay") as RayCast3D

## The route to `_routed_target`, Godot axes.
var _waypoints := PackedVector3Array()
var _waypoint_index := 0
## The move_target the current route (or route request) leads to.
var _routed_target := Vector3.INF
var _route_request_id := -1
var _avoidance_velocity := Vector3.ZERO
var _last_yaw := 0.0

func _ready() -> void:
	actor.placed_by_parent = true
	actor.motion = motion
	agent.velocity_computed.connect(_on_velocity_computed)
	ground_ray.add_exception(body)
	NpcSimulationServer.route_ready.connect(_on_route_ready)
	if reference != null:
		_apply_reference()

func _exit_tree() -> void:
	_disconnect_reference()

func _physics_process(delta: float) -> void:
	if reference == null or reference.simulation_mode != ActorReference.SimulationMode.PHYSICAL_LEASED:
		return
	_update_route()
	var desired := _desired_velocity()
	var velocity := desired
	if absf(_yaw_difference(desired)) > deg_to_rad(turn_in_place_degrees):
		velocity = Vector3.ZERO
	elif agent.avoidance_enabled and desired != Vector3.ZERO:
		agent.velocity = desired
		velocity = _avoidance_velocity
	global_position += velocity * delta
	_snap_to_ground()
	_turn_toward(desired, delta)
	_publish_motion(desired, velocity, delta)
	reference.position = EsmReferencePhysicaliser.authored_position(global_position)
	reference.rotation = EsmReferencePhysicaliser.authored_heading(rotation.y)

## Walk or run speed for this actor: the export times SpeedMult / 100 times
## speed_scale.
func get_speed() -> float:
	var speed := run_speed if running else walk_speed
	var speed_mult := reference.get_actor_values().get_current(ActorValue.SPEED_MULT) if reference != null else 100.0
	return speed * speed_mult / 100.0 * speed_scale

## Places the controller at the reference and hands the reference to the
## actor node.
func _apply_reference() -> void:
	_waypoints.clear()
	_routed_target = Vector3.INF
	_route_request_id = -1
	if reference == null:
		return
	_place_from_reference()
	reference.teleported.connect(_on_reference_teleported)
	agent.set_navigation_map(NpcSimulationServer.local_navigation.get_map(reference.current_space_form_id))
	actor.configure(reference)
	actor.load_actor()

func _disconnect_reference() -> void:
	if reference != null and reference.teleported.is_connected(_on_reference_teleported):
		reference.teleported.disconnect(_on_reference_teleported)

func _place_from_reference() -> void:
	global_position = EsmReferencePhysicaliser.GAMEBRYO_TO_GODOT_BASIS * reference.position
	rotation = Vector3(0.0, -reference.rotation.z, 0.0)
	_last_yaw = rotation.y

## A teleport moves the controller to the reference's new placement and drops
## the current route.
func _on_reference_teleported(_old_space_form_id: int, new_space_form_id: int) -> void:
	_waypoints.clear()
	_routed_target = Vector3.INF
	_route_request_id = -1
	_place_from_reference()
	agent.set_navigation_map(NpcSimulationServer.local_navigation.get_map(new_space_form_id))

## Requests a route when move_target changes; drops the route when there is no
## target.
func _update_route() -> void:
	if not reference.has_move_target:
		_waypoints.clear()
		_routed_target = Vector3.INF
		return
	if reference.move_target == _routed_target:
		return
	_routed_target = reference.move_target
	_waypoints.clear()
	_route_request_id = NpcSimulationServer.request_route(reference.current_space_form_id, reference.position, reference.move_target)

func _on_route_ready(request_id: int, result: Dictionary) -> void:
	if request_id != _route_request_id:
		return
	_route_request_id = -1
	_waypoints.clear()
	_waypoint_index = 0
	if not bool(result.get("found", false)):
		push_warning("NpcController: no route for %s to %s" % [reference.instance_id, _routed_target])
		return
	for point: Vector3 in result["waypoints"]:
		_waypoints.append(EsmReferencePhysicaliser.GAMEBRYO_TO_GODOT_BASIS * point)

## Toward the current waypoint along the agent's local path, at this actor's
## speed; zero when there is nowhere to go. Advances past reached waypoints
## and reports arrival at the last one.
func _desired_velocity() -> Vector3:
	while _waypoint_index < _waypoints.size() and _planar_distance(_waypoints[_waypoint_index]) <= arrive_radius:
		_waypoint_index += 1
		if _waypoint_index == _waypoints.size():
			_waypoints.clear()
			_routed_target = Vector3.INF
			reference.reach_move_target()
			return Vector3.ZERO
	if _waypoint_index >= _waypoints.size():
		return Vector3.ZERO
	agent.target_position = _waypoints[_waypoint_index]
	var toward := agent.get_next_path_position() - global_position
	toward.y = 0.0
	if toward.length() < 0.001:
		return Vector3.ZERO
	return toward.normalized() * get_speed()

func _on_velocity_computed(safe_velocity: Vector3) -> void:
	_avoidance_velocity = safe_velocity

func _planar_distance(point: Vector3) -> float:
	return Vector2(point.x - global_position.x, point.z - global_position.z).length()

## Stands the actor on the collision under it, or on the local navmesh where
## there is none.
func _snap_to_ground() -> void:
	ground_ray.force_raycast_update()
	if ground_ray.is_colliding():
		global_position.y = ground_ray.get_collision_point().y
		return
	var map := agent.get_navigation_map()
	if NavigationServer3D.map_get_regions(map).is_empty():
		return
	global_position.y = NavigationServer3D.map_get_closest_point(map, global_position).y

## How far `direction` is from the actor's facing, radians, positive to the
## left; 0 for no direction.
func _yaw_difference(direction: Vector3) -> float:
	if Vector2(direction.x, direction.z).length() < 0.01:
		return 0.0
	return wrapf(atan2(-direction.x, -direction.z) - rotation.y, -PI, PI)

func _turn_toward(direction: Vector3, delta: float) -> void:
	var step := deg_to_rad(turn_speed_degrees) * delta
	rotation.y += clampf(_yaw_difference(direction), -step, step)

## `desired` is where the controller wants to go, `velocity` where avoidance
## lets it.
func _publish_motion(desired: Vector3, velocity: Vector3, delta: float) -> void:
	var yaw_change := wrapf(rotation.y - _last_yaw, -PI, PI)
	_last_yaw = rotation.y
	var inverse := global_transform.basis.inverse()
	var local_desired := inverse * desired
	motion.velocity = inverse * velocity
	motion.move_input = Vector2(local_desired.x, -local_desired.z).normalized()
	motion.turn_rate = yaw_change / delta if delta > 0.0 else 0.0
	motion.grounded = true
	motion.running = running
	motion.sneaking = false
