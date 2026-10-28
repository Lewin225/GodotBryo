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
## Body capsule is what trigger volumes and the player collide with. Its
## `sync_to_physics` is off: with it on, an AnimatableBody3D only sends its own
## local transform to the physics server, so the capsule stayed where the
## actor was physicalised while the controller moved.
##
## The controller holds the lease while it is in the tree and its space is
## physically loaded (has local navigation): the reference is PHYSICAL_LEASED,
## and this moves it every physics frame, writes its position and heading to
## the reference every `placement_write_seconds` and on arrival, and publishes
## an ActorMotion to the actor node. Otherwise (left the tree, or its streamer
## paused for an interior visit) the actor is NpcSimulationServer's
## (LOW_LEVEL), whose LowLevelTravel moves it; taking the lease back places the
## controller where the reference has got to.

## Walk speed at SpeedMult 100, metres per second.
@export var walk_speed := 1.6
## Run speed at SpeedMult 100, metres per second.
@export var run_speed := 4.0
## Scales both speeds, to tune against the original game by eye.
@export var speed_scale := 1.0
## How fast the actor turns toward where it moves, degrees per second.
@export var turn_speed_degrees := 360.0
## While moving, the reference's position and heading are written once per
## this many seconds (the package rate), and always when the lease is handed
## back; every other reader of the reference runs at this rate or slower.
@export var placement_write_seconds := 0.1
## A waypoint counts as reached within this distance across the ground,
## metres.
@export var arrive_radius := 0.3
## When the way ahead is more than this many degrees off the actor's facing,
## it turns on the spot before moving.
@export var turn_in_place_degrees := 45.0
## Standing in a conversation (not a line said outside one), the actor turns towards its partner once the
## partner is further round than the head can turn, and stops turning within
## this many degrees of facing them.
@export var face_partner_stop_degrees := 10.0
## How fast the actor turns towards its conversation partner, degrees per
## second.
@export var face_partner_turn_speed_degrees := 180.0
## An actor with route left that moves less than `stuck_distance` metres in
## this many seconds is stuck, and is moved to its current waypoint.
@export var stuck_seconds := 3.0
## See `stuck_seconds`.
@export var stuck_distance := 0.25


## How this controller moves its actor, handed to the EsmActorNode once and
## updated in place.
var motion := ActorMotion.new()
## Routes that came back not found, across all controllers. Counted, not
## logged (a warning each floods the debugger with many actors);
## NpcSimulationServer.debug_report shows it.
static var routes_not_found := 0
## Physics layer 2: actor capsules. A capsule is only there to be hit (the
## interact ray, later weapon rays); it has no mask, so it never pairs with
## other capsules or the world, and rays that should find actors add this
## layer. The ground ray keeps to layer 1, the world.
const ACTOR_COLLISION_LAYER := 1 << 1
## Planar speed (metres per second) above which the actor counts as moving
## (ActorReference.is_moving).
const MOVING_SPEED := 0.1
## Debug (DebugNpcControllers): when false, every controller skips its
## per-frame work and leaves avoidance, to see what controllers cost.
static var debug_enabled := true

## The reference as the actor it is.
var actor_reference: ActorReference:
	get:
		return _actor
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
## When the route to `_routed_target` came back not found
## (Time.get_ticks_msec()), or -1.
var _route_failed_msec := -1
## Whether the active package has Always Run (active_package_changed).
var _running := false
## The active package has Always Sneak.
var _sneaking := false
var _avoidance_velocity := Vector3.ZERO
## SpeedMult, read when a route arrives rather than every frame.
var _speed_mult := 100.0
## The waypoint the agent was last given, so its path is requested only when
## it changes (setting `target_position` always requests a new path).
var _agent_target := Vector3.INF
## While crossing a NavigationLink3D: where it goes in and comes out, Godot
## axes; `_link_exit` is INF otherwise.
var _link_entry := Vector3.INF
var _link_exit := Vector3.INF
## Set for the frame the actor steps off a link onto its exit.
var _left_link := false
## Where the current route segment starts: the previous waypoint, or where
## the actor was when the route arrived.
var _segment_start := Vector3.ZERO
## Where the actor was when it last made progress, and how long since.
var _progress_position := Vector3.INF
var _stalled_seconds := 0.0
var _last_yaw := 0.0
## The reference this controller has leased, handed back on leaving the tree
## or changing reference.
var _leased: ActorReference = null
## `reference` as an ActorReference, kept when it changes rather than cast on
## every use.
var _actor: ActorReference = null
## Whether the actor is turning towards its conversation partner.
var _facing_partner := false
## Seconds until position and heading are next written to the reference.
var _placement_write_timer := 0.0

func _ready() -> void:
	super()
	actor.motion = motion
	agent.velocity_computed.connect(_on_velocity_computed)
	_update_avoidance()
	agent.link_reached.connect(_on_link_reached)
	body.collision_layer = ACTOR_COLLISION_LAYER
	body.collision_mask = 0
	ground_ray.collision_mask = 1
	NpcSimulationServer.route_ready.connect(_on_route_ready)
	NpcSimulationServer.local_navigation.local_cells_changed.connect(_on_local_cells_changed)
	# Godot turns physics processing on at the first ready; it runs only while
	# the lease is held.
	set_physics_process(_leased != null)

func _enter_tree() -> void:
	set_physics_process(false)
	_update_lease()


func _exit_tree() -> void:
	check_in()

func _physics_process(delta: float) -> void:
	if not debug_enabled:
		if agent.avoidance_enabled:
			agent.avoidance_enabled = false
		return
	if _actor == null or _actor != _leased or _actor.is_disabled():
		return
	if _actor.sit_state != FurnitureSeating.NOT_SITTING:
		# Seated, or sitting down or standing up: the furniture idles move the
		# body; the controller holds at the marker.
		_publish_idle(delta)
		return
	if _in_conversation():
		# Held in place while talking; the route resumes when the conversation
		# ends, even if the package changed during it.
		_face_conversation_partner(delta)
		_hold_stuck_timer()
		_publish_motion(Vector3.ZERO, Vector3.ZERO, delta)
		return
	_update_route()
	if _waypoint_index >= _waypoints.size() and _link_exit == Vector3.INF:
		_face_conversation_partner(delta)
		_publish_idle(delta)
		ScriptServer.actor_idles.update_standing(_actor)
		return
	var desired := _desired_velocity()
	var velocity := desired
	if absf(_yaw_difference(desired)) > deg_to_rad(turn_in_place_degrees):
		velocity = Vector3.ZERO
		# Turning on the spot: the agent stands still too, so the first step
		# after the turn never uses a velocity computed for the old heading.
		if agent.avoidance_enabled:
			agent.velocity = Vector3.ZERO
		_avoidance_velocity = Vector3.ZERO
	elif agent.avoidance_enabled and desired != Vector3.ZERO:
		agent.velocity = desired
		velocity = _avoidance_velocity
	global_position += velocity * delta
	if _link_exit != Vector3.INF:
		_follow_link_height()
	else:
		_snap_to_ground(_left_link)
	_left_link = false
	_turn_toward(desired, delta)
	_recover_if_stuck(delta)
	_publish_motion(desired, velocity, delta)
	_placement_write_timer -= delta
	if _placement_write_timer <= 0.0:
		_placement_write_timer = placement_write_seconds
		_write_placement()

## Walk or run speed for this actor: the export times SpeedMult / 100 times
## speed_scale.
func get_speed() -> float:
	var speed := run_speed if _running else walk_speed
	return speed * _speed_mult / 100.0 * speed_scale

## Hides a disabled actor and turns its collision off (EsmNode), and takes
## it out of avoidance.
func _apply_enable_state() -> void:
	super()
	_update_avoidance()

## An actor takes part in avoidance, as an agent others steer around, only
## while this controller holds its lease and it is enabled: a hidden or
## off-site controller's agent would otherwise still push visible actors.
func _update_avoidance() -> void:
	if agent == null:
		return
	agent.avoidance_enabled = debug_enabled and _leased != null and reference != null and not reference.is_disabled()

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
	if _actor != null and _actor.active_package_changed.is_connected(_on_active_package_changed):
		_actor.active_package_changed.disconnect(_on_active_package_changed)
	_actor = reference as ActorReference
	if _actor != null:
		_actor.active_package_changed.connect(_on_active_package_changed)
	_on_active_package_changed(null, _actor.active_package if _actor != null else null)
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
		_update_lease()

## Reads the flags the controller acts on from the actor's new package.
func _on_active_package_changed(_old_package: PackageBase, new_package: PackageBase) -> void:
	_running = new_package != null and new_package.is_always_run()
	_sneaking = new_package != null and new_package.is_always_sneak()

## A teleport moves the controller to the reference's new placement, drops the
## route and points the agent at the new space's map. Across spaces the
## streamer that owns the controller moves or frees it as well.
func _on_reference_teleported(old_space_form_id: int, new_space_form_id: int) -> void:
	super(old_space_form_id, new_space_form_id)
	transform = EsmReferencePhysicaliser.placement_transform(reference.position, reference.rotation, reference.scale)
	_reset_route()
	_last_yaw = rotation.y
	agent.set_navigation_map(NpcSimulationServer.local_navigation.get_map(new_space_form_id))
	_update_lease()

## A space gained its first local cell or lost its last: the lease may follow.
func _on_local_cells_changed(space_form_id: int) -> void:
	if _actor != null and _actor.current_space_form_id == space_form_id:
		_update_lease()

## Holds the lease while the reference's space is physically loaded, and
## hands it back when it is not. Checked when the reference, its space or the
## space's local cells change, and on entering the tree.
func _update_lease() -> void:
	var loaded := actor_reference != null and NpcSimulationServer.local_navigation.has_local_cells(actor_reference.current_space_form_id)
	if loaded and _leased != actor_reference:
		_release_lease()
		_take_lease()
	elif not loaded and _leased != null:
		_release_lease()

## Hands the actor back to NpcSimulationServer with its final placement:
## before something else moves it (ScriptServer.apply_pending_moves), so the
## move is the placement that stands, and on leaving the tree (the CELL
## unloads or the reference leaves it) before the node is destroyed.
func check_in() -> void:
	_release_lease()

## Takes the lease and places the controller where the reference has got to.
## The controller runs only while it holds the lease.
func _take_lease() -> void:
	_leased = actor_reference
	set_physics_process(true)
	_leased.simulation_mode = ActorReference.SimulationMode.PHYSICAL_LEASED
	transform = EsmReferencePhysicaliser.placement_transform(reference.position, reference.rotation, reference.scale)
	_last_yaw = rotation.y
	_reset_route()
	_update_avoidance()

## Writes the final placement and hands the actor back to NpcSimulationServer.
func _release_lease() -> void:
	if _leased == null:
		return
	if is_inside_tree() and _leased == actor_reference:
		_write_placement()
	_leased.simulation_mode = ActorReference.SimulationMode.LOW_LEVEL
	_leased.is_moving = false
	_leased.is_running = false
	_leased = null
	set_physics_process(false)
	_update_avoidance()

func _write_placement() -> void:
	reference.position = EsmReferencePhysicaliser.authored_position(global_position)
	reference.rotation = EsmReferencePhysicaliser.authored_heading(rotation.y)

## Moves an actor that has route left but has not moved `stuck_distance` in
## `stuck_seconds` (blocked by a body, a wall or a closed door) to its current
## waypoint, standing it on the ground there.
func _recover_if_stuck(delta: float) -> void:
	if _waypoint_index >= _waypoints.size():
		_progress_position = Vector3.INF
		_stalled_seconds = 0.0
		return
	if _progress_position == Vector3.INF or global_position.distance_to(_progress_position) > stuck_distance:
		_progress_position = global_position
		_stalled_seconds = 0.0
		return
	_stalled_seconds += delta
	if _stalled_seconds < stuck_seconds:
		return
	global_position = _waypoints[_waypoint_index]
	_link_entry = Vector3.INF
	_link_exit = Vector3.INF
	_snap_to_ground(true)
	_progress_position = global_position
	_stalled_seconds = 0.0

## Restarts the stuck check from here, so standing still on purpose (in a
## conversation) is not taken for being stuck.
func _hold_stuck_timer() -> void:
	_progress_position = global_position
	_stalled_seconds = 0.0

## Nowhere to go: publishes standing still, turning on the spot if the actor
## was, and leaves the reference as it is.
func _publish_idle(delta: float) -> void:
	_recover_if_stuck(delta)
	_publish_motion(Vector3.ZERO, Vector3.ZERO, delta)

func _reset_route() -> void:
	_agent_target = Vector3.INF
	_progress_position = Vector3.INF
	_stalled_seconds = 0.0
	_link_entry = Vector3.INF
	_link_exit = Vector3.INF
	_cancel_route_request()
	_waypoints.clear()
	_waypoint_index = 0
	_routed_target = Vector3.INF
	_route_failed_msec = -1

## Requests a route when move_target changes; drops the route when there is no
## target.
func _update_route() -> void:
	if not _actor.has_move_target:
		_cancel_route_request()
		_waypoints.clear()
		_routed_target = Vector3.INF
		return
	if _actor.move_target == _routed_target and not _should_retry_route():
		return
	_cancel_route_request()
	_routed_target = _actor.move_target
	_waypoints.clear()
	_route_failed_msec = -1
	_route_request_id = NpcSimulationServer.request_route(reference.current_space_form_id, reference.position, _actor.move_target, true)

## Whether the route to the current target came back not found at least
## route_retry_seconds ago, so it is asked for again.
func _should_retry_route() -> bool:
	if _route_failed_msec < 0:
		return false
	return Time.get_ticks_msec() - _route_failed_msec >= NpcSimulationServer.route_retry_seconds * 1000.0

## Cancels a route request still waiting on NpcSimulationServer's thread.
func _cancel_route_request() -> void:
	if _route_request_id != -1:
		NpcSimulationServer.cancel_request(_route_request_id)
		_route_request_id = -1

func _on_route_ready(request_id: int, result: Dictionary) -> void:
	if request_id != _route_request_id:
		return
	_route_request_id = -1
	_waypoints.clear()
	_waypoint_index = 0
	if not bool(result.get("found", false)):
		routes_not_found += 1
		_route_failed_msec = Time.get_ticks_msec()
		return
	for point: Vector3 in result["waypoints"]:
		_waypoints.append(EsmReferencePhysicaliser.GAMEBRYO_TO_GODOT_BASIS * point)
	_agent_target = Vector3.INF
	_segment_start = global_position
	_speed_mult = actor_reference.get_actor_values().get_current(ActorValue.SPEED_MULT)

## Toward the current waypoint along the agent's local path, at this actor's
## speed; zero when there is nowhere to go. Advances past reached waypoints
## and reports arrival at the last one.
func _desired_velocity() -> Vector3:
	while _waypoint_index < _waypoints.size() and _planar_distance(_waypoints[_waypoint_index]) <= arrive_radius:
		_segment_start = _waypoints[_waypoint_index]
		_waypoint_index += 1
		if _waypoint_index == _waypoints.size():
			_waypoints.clear()
			_routed_target = Vector3.INF
			_write_placement()
			actor_reference.reach_move_target()
			return Vector3.ZERO
	if _waypoint_index >= _waypoints.size():
		return Vector3.ZERO
	if _link_exit != Vector3.INF:
		if _planar_distance(_link_exit) > arrive_radius:
			return _toward(_link_exit)
		global_position = _link_exit
		_segment_start = _link_exit
		_link_exit = Vector3.INF
		_left_link = true
	if _agent_target != _waypoints[_waypoint_index]:
		_agent_target = _waypoints[_waypoint_index]
		agent.target_position = _agent_target
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

## Stands the actor on the collision under it, or where there is none on its
## route: waypoints lie on the navmesh, so the height along the current
## segment is the navmesh's, with no query (a navigation map's closest-point
## query scans every polygon). The ray's hit is from the last physics step
## unless `jumped` (the actor was just moved more than a step), which casts it
## afresh.
func _snap_to_ground(jumped := false) -> void:
	if jumped:
		ground_ray.force_raycast_update()
	if ground_ray.is_colliding():
		global_position.y = ground_ray.get_collision_point().y
		return
	if _waypoint_index >= _waypoints.size():
		return
	var to := _waypoints[_waypoint_index]
	var span := Vector2(to.x - _segment_start.x, to.z - _segment_start.z).length()
	var progress := 1.0 - _planar_distance(to) / span if span > 0.001 else 1.0
	global_position.y = lerpf(_segment_start.y, to.y, clampf(progress, 0.0, 1.0))

## How far `direction` is from the actor's facing, radians, positive to the
## left; 0 for no direction.
func _yaw_difference(direction: Vector3) -> float:
	if Vector2(direction.x, direction.z).length() < 0.01:
		return 0.0
	return wrapf(atan2(-direction.x, -direction.z) - rotation.y, -PI, PI)

## Whether the actor is the speaker or listener of the running conversation.
func _in_conversation() -> bool:
	return DialogueServer.get_conversation_speaker() == _actor or DialogueServer.get_conversation_listener() == _actor

## Turns the standing actor towards its conversation partner: starts once the
## partner is beyond the head's reach, and turns until within
## face_partner_stop_degrees. Writes the new heading to the reference when the
## turn ends.
func _face_conversation_partner(delta: float) -> void:
	var tracking := actor.head_tracking if actor != null else null
	var partner := tracking.get_conversation_partner() if tracking != null else null
	if partner == null or partner.current_space_form_id != _actor.current_space_form_id:
		_facing_partner = false
		return
	# Towards the partner's head: a seated actor's reference is at the
	# furniture marker, in front of the chair.
	var to_partner := tracking.get_eye_position_of(partner) - global_position
	var difference := absf(_yaw_difference(to_partner))
	if difference > tracking.get_left_right_reach():
		_facing_partner = true
	if not _facing_partner:
		return
	if difference <= deg_to_rad(face_partner_stop_degrees):
		_facing_partner = false
		_write_placement()
		return
	var step := deg_to_rad(face_partner_turn_speed_degrees) * delta
	rotation.y += clampf(_yaw_difference(to_partner), -step, step)

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
	motion.running = _running
	motion.sneaking = _sneaking
	if _actor != null:
		_actor.is_moving = Vector2(velocity.x, velocity.z).length() > MOVING_SPEED
		_actor.is_running = _actor.is_moving and _running
		_actor.is_sneaking = _sneaking
