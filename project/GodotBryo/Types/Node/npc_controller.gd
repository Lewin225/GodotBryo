class_name NpcController
extends EsmNode

## A physicalised NPC or creature: the cheaper sibling of PlayerController
## (npc_controller.tscn), and the node registered for its reference
## (EsmNode.node_for), so streamers place, move and free the whole actor
## through it. It loads no model itself: it hands the reference to its
## EsmActorNode child and tells it to load or unload, and the child renders
## the actor and chooses its clips.
##
## NpcSimulationServer decides where the actor goes
## (`ActorReference.move_target`) and routes it; this follows the route's
## waypoints one hop at a time with its NavigationAgent3D on the space's local
## navigation map, which adds avoidance between agents. Movement is kinematic:
## the navmesh says where an actor can walk, so there is no move_and_slide. The
## Body capsule is what trigger volumes and the player collide with.
##
## In the tree the controller holds the lease: the reference is
## PHYSICAL_LEASED, and this writes its position and heading every physics
## frame and publishes an ActorMotion to the actor node. Leaving the tree
## hands it back to NpcSimulationServer (LOW_LEVEL).

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

@export_group("Debug")
## A test stand-in for packages: keeps the reference's move_target on the
## player (the possessed actor) while both are in the same space.
@export var debug_follow_player := false
## Stops following within this distance of the player, metres.
@export var debug_follow_distance := 1.5
## Re-targets once the player is this far from the current target, metres.
@export var debug_retarget_distance := 1.0
@export_group("")

## How this controller moves its actor, handed to the EsmActorNode once and
## updated in place.
var motion := ActorMotion.new()

## The reference as the actor it is.
var actor_reference: ActorReference:
	get:
		return reference as ActorReference
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
## While crossing a NavigationLink3D: where it goes in and comes out, Godot
## axes; `_link_exit` is INF otherwise.
var _link_entry := Vector3.INF
var _link_exit := Vector3.INF
var _last_yaw := 0.0
## The reference this controller has leased, handed back on leaving the tree
## or changing reference.
var _leased: ActorReference = null

func _ready() -> void:
	super()
	actor.motion = motion
	agent.velocity_computed.connect(_on_velocity_computed)
	agent.link_reached.connect(_on_link_reached)
	ground_ray.add_exception(body)
	NpcSimulationServer.route_ready.connect(_on_route_ready)

func _enter_tree() -> void:
	_take_lease()

func _exit_tree() -> void:
	_release_lease()

func _physics_process(delta: float) -> void:
	var actor_ref := actor_reference
	if actor_ref == null or actor_ref != _leased or actor_ref.is_disabled():
		return
	if debug_follow_player:
		_update_debug_follow()
	_update_route()
	var desired := _desired_velocity()
	var velocity := desired
	if absf(_yaw_difference(desired)) > deg_to_rad(turn_in_place_degrees):
		velocity = Vector3.ZERO
	elif agent.avoidance_enabled and desired != Vector3.ZERO:
		agent.velocity = desired
		velocity = _avoidance_velocity
	global_position += velocity * delta
	if _link_exit != Vector3.INF:
		_follow_link_height()
	else:
		_snap_to_ground()
	_turn_toward(desired, delta)
	_publish_motion(desired, velocity, delta)
	_write_placement()

## Walk or run speed for this actor: the export times SpeedMult / 100 times
## speed_scale.
func get_speed() -> float:
	var speed := run_speed if running else walk_speed
	var speed_mult := actor_reference.get_actor_values().get_current(ActorValue.SPEED_MULT) if actor_reference != null else 100.0
	return speed * speed_mult / 100.0 * speed_scale

## Activation is presented by the actor node.
func on_activated(activator: EsmReference) -> void:
	actor.on_activated(activator)

## The controller has no model of its own; the actor node loads the actor.
func _should_request_nif() -> bool:
	return false

## A new reference: hands back the old lease, places the controller, and has
## the actor node drop the old actor and load the new one.
func _reference_changed() -> void:
	_release_lease()
	_reset_route()
	if actor != null:
		actor.unload_actor()
	if reference == null:
		return
	transform = EsmReferencePhysicaliser.placement_transform(reference.position, reference.rotation, reference.scale)
	_last_yaw = rotation.y
	agent.set_navigation_map(NpcSimulationServer.local_navigation.get_map(reference.current_space_form_id))
	actor.configure(reference)
	actor.load_actor()
	if is_inside_tree():
		_take_lease()

## A teleport moves the controller to the reference's new placement, drops the
## route and points the agent at the new space's map. Across spaces the
## streamer that owns the controller moves or frees it as well.
func _on_reference_teleported(old_space_form_id: int, new_space_form_id: int) -> void:
	super(old_space_form_id, new_space_form_id)
	transform = EsmReferencePhysicaliser.placement_transform(reference.position, reference.rotation, reference.scale)
	_reset_route()
	_last_yaw = rotation.y
	agent.set_navigation_map(NpcSimulationServer.local_navigation.get_map(new_space_form_id))

func _take_lease() -> void:
	if actor_reference == null or _leased == actor_reference:
		return
	_leased = actor_reference
	_leased.simulation_mode = ActorReference.SimulationMode.PHYSICAL_LEASED

## Writes the final placement and hands the actor back to NpcSimulationServer.
func _release_lease() -> void:
	if _leased == null:
		return
	if is_inside_tree() and _leased == actor_reference:
		_write_placement()
	_leased.simulation_mode = ActorReference.SimulationMode.LOW_LEVEL
	_leased = null

func _write_placement() -> void:
	reference.position = EsmReferencePhysicaliser.authored_position(global_position)
	reference.rotation = EsmReferencePhysicaliser.authored_heading(rotation.y)

func _reset_route() -> void:
	_link_entry = Vector3.INF
	_link_exit = Vector3.INF
	_waypoints.clear()
	_waypoint_index = 0
	_routed_target = Vector3.INF
	_route_request_id = -1

## Points move_target at the player, or clears it once close enough.
func _update_debug_follow() -> void:
	var player := ScriptServer.player_reference
	if player == null or player.current_space_form_id != reference.current_space_form_id:
		return
	if reference.position.distance_to(player.position) <= debug_follow_distance:
		if actor_reference.has_move_target:
			actor_reference.clear_move_target()
		return
	if not actor_reference.has_move_target or actor_reference.move_target.distance_to(player.position) > debug_retarget_distance:
		actor_reference.set_move_target(player.position)

## Requests a route when move_target changes; drops the route when there is no
## target.
func _update_route() -> void:
	if not actor_reference.has_move_target:
		_waypoints.clear()
		_routed_target = Vector3.INF
		return
	if actor_reference.move_target == _routed_target:
		return
	_routed_target = actor_reference.move_target
	_waypoints.clear()
	_route_request_id = NpcSimulationServer.request_route(reference.current_space_form_id, reference.position, actor_reference.move_target)

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
			actor_reference.reach_move_target()
			return Vector3.ZERO
	if _waypoint_index >= _waypoints.size():
		return Vector3.ZERO
	if _link_exit != Vector3.INF:
		if _planar_distance(_link_exit) > arrive_radius:
			return _toward(_link_exit)
		global_position = _link_exit
		_link_exit = Vector3.INF
	agent.target_position = _waypoints[_waypoint_index]
	var next := agent.get_next_path_position()
	# The agent stops within its own target distance; the last step to the
	# waypoint is straight.
	if agent.is_navigation_finished():
		next = _waypoints[_waypoint_index]
	return _toward(next)

## This actor's speed across the ground toward `point`; zero once there.
func _toward(point: Vector3) -> Vector3:
	var toward := point - global_position
	toward.y = 0.0
	if toward.length() < 0.001:
		return Vector3.ZERO
	return toward.normalized() * get_speed()

## The agent reached a link's entry: walk straight to its exit, which may lie
## behind the actor, before following the agent's path again.
func _on_link_reached(details: Dictionary) -> void:
	_link_entry = details["link_entry_position"]
	_link_exit = details["link_exit_position"]

## On a link the ground under the actor belongs to neither record: its height
## goes from the entry's to the exit's with its progress across the ground.
func _follow_link_height() -> void:
	var span := Vector2(_link_exit.x - _link_entry.x, _link_exit.z - _link_entry.z).length()
	var progress := 1.0 - _planar_distance(_link_exit) / span if span > 0.001 else 1.0
	global_position.y = lerpf(_link_entry.y, _link_exit.y, clampf(progress, 0.0, 1.0))

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
