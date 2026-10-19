class_name PackageRunner
extends Node

## Chooses and runs every tracked actor's package, on screen and off alike: it
## decides where an actor goes (`ActorReference.move_target`) and NpcController
## or LowLevelTravel moves it there. NpcSimulationServer tracks every actor it
## indexes (`track()`).
##
## Selection (GECK "How Are Packages Evaluated"): the actor's `script_package`
## (AddScriptPackage) if it has one, else the first of its packages, top to
## bottom, whose schedule and conditions hold, into `active_package`. Packages
## come from the base, or its template when the template flag Use AI Packages is
## set. An actor is evaluated on its sweep turn every `evaluation_seconds`, and
## at once on EvaluatePackage and when its script package changes.
##
## Budget (README "Tick rates"): actors run in two round-robin sweeps, each
## visiting every member once per its period however many there are: leased
## actors every `leased_sweep_seconds` (10 times a second), the rest every
## `unleased_sweep_seconds`, and LowLevelTravel moves each unleased actor on its
## turn by the time since its last.
##
## Reaching a target in another space: NpcSimulationServer plans the sequence
## of load doors on its own thread (`request_door_sequence`, doors only), and
## the actor walks to each door in turn and activates it; each leg's walking
## route is computed when the leg starts. An unleased actor keeps to its
## sequence until it is in the space it was planned for; a leased one plans
## again as soon as its target changes space. A plan that finds no doors is
## not retried until the target changes space or `plan_retry_seconds` pass.
##
## Implemented package types: FOLLOW, TRAVEL and DIALOGUE. Others leave the actor where
## it is. A package with Always Run makes the actor run wherever it moves.
##
## A package begins when selection chooses it (its On Begin runs). Travel goes
## to Location 1 and stops at the edge of its radius; radius 0 means the point
## itself, and a furniture reference there is used (ScriptServer.begin_use).
## Arriving completes it (`ActorReference.package_completed`, its On End runs,
## and the actor chooses again); a completed package that selection keeps
## choosing is not run again. When another package replaces it, the actor
## leaves the furniture the package seated it in. Events run their script with
## the actor as subject, say their topic and play their idle. On Change runs
## when AddScriptPackage adds the package already active, and when another
## package replaces it before it is done (inferred; Plans/Completed Plans/Actors/stage_f.md).
##
## Schedules (PSDT; over FalloutNV.esm's 4,163 PACK, month is always Any and date
## always 0): a package with an hour is due from it for its duration in hours,
## wrapping past midnight, so a duration of 0 is never due; one without an hour
## is always due, whatever its duration. Day of week (set on 53 packages, none of
## VCG01's) is not checked yet. With no game clock, only packages without an hour
## are due.

enum { PLAN_PENDING, PLAN_READY, PLAN_FAILED }

## PKDD Dialogue Type 1, Say To (0 is Conversation; xEdit).
const DIALOGUE_TYPE_SAY_TO := 1
## ACBS template flag 0x20, Use AI Packages: packages come from the template.
const TEMPLATE_USE_AI_PACKAGES := 0x20
## PTDT Count / Distance is in Gamebryo units (common/units.h).
const UNITS_TO_METERS := 1.0 / 70.0
## A follower is sent toward its target again once the target has moved this
## far from where it was sent, metres, or RETARGET_FRACTION of the follower's
## distance to it if that is more: a follower far away keeps its route for
## small moves, which would each cost a long route.
const RETARGET_DISTANCE := 1.0
const RETARGET_FRACTION := 0.25

## Every leased actor with a package runs once per this many seconds. Its
## NpcController moves it every frame toward the target this sets.
@export var leased_sweep_seconds := 0.1:
	set(value):
		leased_sweep_seconds = value
		_leased.period = value
## Every unleased actor with a package runs once per this many seconds.
@export var unleased_sweep_seconds := 1.0:
	set(value):
		unleased_sweep_seconds = value
		_unleased.period = value
## A route between spaces that was not found is planned again after this many
## seconds, unless the target changes space first.
@export var plan_retry_seconds := 10.0
## Each actor's package is chosen again this often (GECK: about every 10 s).
@export var evaluation_seconds := 10.0

## Leased and unleased actors with a package.
var _leased := Sweep.new(0.1)
var _unleased := Sweep.new(1.0)
## ActorReference -> Time.get_ticks_msec() of its last run.
var _last_run_msec: Dictionary = {}
## ActorReference -> its simulation_mode_changed handler.
var _mode_handlers: Dictionary = {}
## ActorReference -> its plan for reaching a target in another space:
## {"target_space", "state": PLAN_PENDING / PLAN_READY / PLAN_FAILED,
## "request_id"; once ready "portals" (NpcPortal, in order), "next" (index of
## the door being walked to) and "walking"; once failed "retry_msec"}.
var _door_plans: Dictionary = {}
## Door sequence request id -> the actor it is for.
var _actors_by_request: Dictionary = {}
## ActorReference -> Time.get_ticks_msec() when it is next evaluated; 0 means
## on its next turn.
var _next_evaluation_msec: Dictionary = {}
## ActorReference -> its Travel package's state: {"sent": bool, and for Near
## current location "space_form_id" and "position", taken when it began}.
var _travels: Dictionary = {}
## ActorReference -> the furniture its package seated it in.
var _seated_by_package: Dictionary = {}
## Messages already warned, once each.
var _warned: Dictionary = {}

var travel: LowLevelTravel:
	get:
		return get_parent().get_node_or_null(^"LowLevelTravel") as LowLevelTravel

func _ready() -> void:
	get_parent().door_sequence_ready.connect(_on_door_sequence_ready)

## Has PackageRunner choose and run `actor`'s packages from now on.
func track(actor: ActorReference) -> void:
	if actor == null or _mode_handlers.has(actor):
		return
	_last_run_msec[actor] = Time.get_ticks_msec()
	_next_evaluation_msec[actor] = 0
	var handler := _on_simulation_mode_changed.bind(actor)
	_mode_handlers[actor] = handler
	actor.simulation_mode_changed.connect(handler)
	_file(actor)

## Stops choosing and running `actor`'s packages, leaving its package and target
## as they are.
func untrack(actor: ActorReference) -> void:
	if _mode_handlers.has(actor):
		actor.simulation_mode_changed.disconnect(_mode_handlers[actor])
		_mode_handlers.erase(actor)
	_drop_plan(actor)
	_leased.remove(actor)
	_unleased.remove(actor)
	_last_run_msec.erase(actor)
	_next_evaluation_msec.erase(actor)
	_travels.erase(actor)
	_seated_by_package.erase(actor)
	travel.forget(actor)

## Gives `actor` `package` as its script package (AddScriptPackage), or clears
## it with null (RemoveScriptPackage); either way the actor chooses again at once.
func set_script_package(actor: ActorReference, package: PackageBase) -> void:
	# Added again while it runs: its On Change runs (VCG01 stage 7: "this is
	# the second time we call this - it triggers the OnChange animation").
	if package != null and package == actor.script_package and package == actor.active_package:
		_run_event(actor, package.on_change)
		return
	actor.script_package = package
	track(actor)
	evaluate_now(actor)

## Has `actor` choose its package at once (EvaluatePackage).
func evaluate_now(actor: ActorReference) -> void:
	if _next_evaluation_msec.has(actor):
		_evaluate(actor)

## Debug: gives `package` (null clears it) as the script package of every actor
## NpcSimulationServer tracks, the player excepted. Returns how many actors it
## set.
func set_script_package_for_all(package: PackageBase) -> int:
	var count := 0
	for actor: ActorReference in get_parent().actors_by_instance_id.values():
		if actor == ScriptServer.player_reference:
			continue
		set_script_package(actor, package)
		count += 1
	return count

## The package `actor` would run now: its script package, else the first of its
## packages whose schedule and conditions hold; null when none does.
func choose_package(actor: ActorReference) -> PackageBase:
	if actor.script_package != null:
		return actor.script_package
	var source := ActorBase.template_source(actor.base, TEMPLATE_USE_AI_PACKAGES)
	if source == null:
		return null
	var hour := _game_hour()
	for package: PackageBase in source.packages:
		if package == null or not is_scheduled(package, hour):
			continue
		if ScriptServer.evaluate_conditions(package.conditions, ConditionContext.new(actor)):
			return package
	return null

## Whether `package`'s schedule lets it run at `hour` (-1: no game clock).
static func is_scheduled(package: PackageBase, hour: float) -> bool:
	if package.schedule_time < 0:
		return true
	if hour < 0.0:
		return false
	var since_start := fposmod(hour - float(package.schedule_time), 24.0)
	return since_start < float(package.schedule_duration_hours)

func _game_hour() -> float:
	var clock = ScriptServer.function_registry.game_time_manager
	if clock == null:
		return -1.0
	return clock.game_hour

func _physics_process(_delta: float) -> void:
	for actor in _leased.take():
		_run(actor)
	for actor in _unleased.take():
		var elapsed := _seconds_since_last_run(actor)
		_run(actor)
		travel.advance(actor, elapsed)

## One run of an actor's package, choosing it first when its evaluation is due.
func _run(actor: ActorReference) -> void:
	_last_run_msec[actor] = Time.get_ticks_msec()
	if actor.is_disabled():
		return
	if Time.get_ticks_msec() >= int(_next_evaluation_msec.get(actor, 0)):
		_evaluate(actor)
	var package := actor.active_package
	if package == null:
		return
	if actor.package_completed:
		return
	match package.package_type:
		PackageBase.PackageType.FOLLOW:
			_follow(actor, package)
		PackageBase.PackageType.TRAVEL:
			_travel(actor, package)
		PackageBase.PackageType.DIALOGUE:
			_dialogue(actor, package)

## Chooses `actor`'s package; a different one replaces the old one's plan and
## target.
func _evaluate(actor: ActorReference) -> void:
	_next_evaluation_msec[actor] = Time.get_ticks_msec() + int(evaluation_seconds * 1000.0)
	var chosen := choose_package(actor)
	if chosen == actor.active_package:
		return
	# Replaced before it is done: its On Change runs (inferred from the name;
	# Plans/Completed Plans/Actors/stage_f.md).
	if actor.active_package != null and not actor.package_completed:
		_run_event(actor, actor.active_package.on_change)
	_end_package(actor)
	actor.package_completed = false
	actor.active_package = chosen
	_drop_plan(actor)
	travel.forget(actor)
	actor.clear_move_target()
	if chosen != null:
		_begin_package(actor, chosen)

## A package starts: a Location 1 of Near current location takes the actor's
## position now, and its On Begin runs.
func _begin_package(actor: ActorReference, package: PackageBase) -> void:
	var state := {"sent": false}
	if package.has_location_1 and package.location_1_type == PackageBase.LocationType.NEAR_CURRENT_LOCATION:
		state["space_form_id"] = actor.current_space_form_id
		state["position"] = actor.position
	_travels[actor] = state
	_run_event(actor, package.on_begin)

## The active package stops: the actor leaves furniture the package seated it
## in.
func _end_package(actor: ActorReference) -> void:
	var seat: EsmReference = _seated_by_package.get(actor)
	if seat != null and actor.using == seat:
		ScriptServer.end_use(actor)
	_seated_by_package.erase(actor)
	_travels.erase(actor)

## Travel: goes to Location 1 and arrives at the edge of its radius, or at the
## point for radius 0.
func _travel(actor: ActorReference, package: PackageBase) -> void:
	var destination := _location(actor, package, 1)
	if destination.is_empty():
		return
	if _move_to(actor, destination, float(package.location_1_radius) * UNITS_TO_METERS):
		_arrive(actor, package, destination)

## Moves `actor` toward `destination` (through load doors when it is in another
## space); true once it has arrived: within `radius` metres when that is above
## 0, else when its route to the point has ended.
func _move_to(actor: ActorReference, destination: Dictionary, radius: float) -> bool:
	var space: int = destination["space_form_id"]
	var position: Vector3 = destination["position"]
	var state: Dictionary = _travels.get(actor, {"sent": false})
	_travels[actor] = state
	var plan: Dictionary = _door_plans.get(actor, {})
	if space != actor.current_space_form_id or _keeps_to_plan(actor, plan):
		state["sent"] = false
		_go_through_doors(actor, space, position)
		return false
	_drop_plan(actor)
	if radius > 0.0 and actor.position.distance_to(position) <= radius:
		actor.clear_move_target()
		return true
	if bool(state["sent"]) and not actor.has_move_target:
		return true
	if not actor.has_move_target or actor.move_target.distance_to(position) > RETARGET_DISTANCE:
		actor.set_move_target(position)
		state["sent"] = true
	return false

## Dialogue (GECK "Dialogue Package"): goes to Location 1, the start/wait
## location; waits until Target 1 is at Location 2, the trigger location, when
## the package has one; then goes to the target and, within Target 1's Count /
## Distance, starts the conversation (PKDD Conversation; with the player that
## is the force-greet) or says the topic (Say To), GREETING when PKDD names
## none. Doing so completes the package.
func _dialogue(actor: ActorReference, package: PackageBase) -> void:
	var state: Dictionary = _travels.get(actor, {"sent": false})
	_travels[actor] = state
	if not bool(state.get("waited", false)):
		var wait := _location(actor, package, 1)
		if not wait.is_empty() and not _move_to(actor, wait, float(package.location_1_radius) * UNITS_TO_METERS):
			return
		state["waited"] = true
		state["sent"] = false
	var target := _target_1(actor, package)
	if target == null or target.current_space_form_id != actor.current_space_form_id:
		return
	if not bool(state.get("triggered", false)):
		if package.has_location_2 and not _at_trigger(target, package):
			return
		state["triggered"] = true
	var distance := float(package.target_1_count_or_distance) * UNITS_TO_METERS
	if actor.position.distance_to(target.position) > distance:
		var retarget := maxf(RETARGET_DISTANCE, actor.position.distance_to(target.position) * RETARGET_FRACTION)
		if not actor.has_move_target or actor.move_target.distance_to(target.position) > retarget:
			actor.set_move_target(target.position)
		return
	actor.clear_move_target()
	actor.package_completed = true
	if package.dialogue_type == DIALOGUE_TYPE_SAY_TO:
		var topic := package.dialogue_topic if package.dialogue_topic != null else EsmServer.find_base_by_editor_id("GREETING") as DialogueTopicBase
		DialogueServer.say(actor, topic, target)
	else:
		DialogueServer.start_conversation(actor, target, package.dialogue_topic)
	_run_event(actor, package.on_end)
	evaluate_now(actor)

## Whether `target` is at the package's Location 2: within its radius, or for
## radius 0 inside the location reference's XPRM primitive (a trigger volume),
## which is an inference: a radius-0 point cannot be stood on.
func _at_trigger(target: EsmReference, package: PackageBase) -> bool:
	var trigger := package.get_location_reference(2)
	if trigger == null or trigger.current_space_form_id != target.current_space_form_id:
		return false
	if package.location_2_radius > 0:
		return target.position.distance_to(trigger.position) <= float(package.location_2_radius) * UNITS_TO_METERS
	return is_inside_primitive(trigger, target.position)

## Whether `point` (Gamebryo axes, metres) is inside `reference`'s XPRM
## primitive, laid out as EsmPrimitiveVolume lays it out.
static func is_inside_primitive(reference: EsmReference, point: Vector3) -> bool:
	if reference.primitive_type == EsmReference.PrimitiveType.NONE:
		return false
	var placement := EsmReferencePhysicaliser.placement_transform(reference.position, reference.rotation, reference.scale)
	var local := placement.affine_inverse() * (EsmReferencePhysicaliser.GAMEBRYO_TO_GODOT_BASIS * point)
	var bounds := reference.primitive_bounds
	if reference.primitive_type == EsmReference.PrimitiveType.SPHERE:
		return local.length() <= maxf(bounds.x, 0.01)
	var half := Vector3(bounds.x, bounds.z, bounds.y).abs()
	return absf(local.x) <= half.x and absf(local.y) <= half.y and absf(local.z) <= half.z

## Travel arrived: completes the package, uses the furniture at a radius-0
## furniture destination, runs On End, and has the actor choose again.
func _arrive(actor: ActorReference, package: PackageBase, destination: Dictionary) -> void:
	actor.clear_move_target()
	actor.package_completed = true
	var reference: EsmReference = destination.get("reference")
	if reference is FurnitureReference and package.location_1_radius == 0:
		if ScriptServer.begin_use(actor, reference):
			_seated_by_package[actor] = reference
	_run_event(actor, package.on_end)
	evaluate_now(actor)

## Location `index` (1 or 2) as {"space_form_id", "position", and "reference"
## when it names one}; empty when it does not resolve.
func _location(actor: ActorReference, package: PackageBase, index: int) -> Dictionary:
	var type := package.location_1_type if index == 1 else package.location_2_type
	match type:
		PackageBase.LocationType.NEAR_REFERENCE:
			return _reference_destination(package.get_location_reference(index))
		PackageBase.LocationType.NEAR_LINKED_REFERENCE:
			if actor.linked_reference_form_id == 0:
				return {}
			return _reference_destination(EsmServer.get_reference("authored:%08X" % actor.linked_reference_form_id))
		PackageBase.LocationType.NEAR_EDITOR_LOCATION:
			return EsmServer.get_authored_placement(actor)
		PackageBase.LocationType.NEAR_CURRENT_LOCATION:
			var state: Dictionary = _travels.get(actor, {})
			if not state.has("position"):
				return {}
			return {"space_form_id": state["space_form_id"], "position": state["position"]}
	_warn_once("PackageRunner: location type %s is not resolved yet (%s)" % [PackageBase.LocationType.keys()[type], package.editor_id])
	return {}

func _reference_destination(reference: EsmReference) -> Dictionary:
	if reference == null or reference.current_space_form_id == 0:
		return {}
	return {"space_form_id": reference.current_space_form_id, "position": reference.position, "reference": reference}

## A package event, in the GECK's order: its script runs with the actor as
## subject, its topic is said, and its idle plays (ScriptServer's ActorIdles).
func _run_event(actor: ActorReference, event: PackageEventCollection) -> void:
	if event == null:
		return
	if not event.script_source.strip_edges().is_empty():
		ScriptServer.run_result_script(event.script_source, actor)
	if event.topic != null:
		DialogueServer.say(actor, event.topic, null)
	if event.idle != null:
		ScriptServer.actor_idles.play(actor, event.idle)

func _warn_once(message: String) -> void:
	if _warned.has(message):
		return
	_warned[message] = true
	push_warning(message)

## Follow: stays within the package's Count / Distance of Target 1, going
## through load doors when the target is in another space.
func _follow(actor: ActorReference, package: PackageBase) -> void:
	var target := _target_1(actor, package)
	if target == null or target.current_space_form_id == 0:
		actor.clear_move_target()
		return
	var plan: Dictionary = _door_plans.get(actor, {})
	if target.current_space_form_id != actor.current_space_form_id or _keeps_to_plan(actor, plan):
		_go_through_doors(actor, target.current_space_form_id, target.position)
		return
	_drop_plan(actor)
	var distance := float(package.target_1_count_or_distance) * UNITS_TO_METERS
	if actor.position.distance_to(target.position) <= distance:
		if actor.has_move_target:
			actor.clear_move_target()
		return
	var retarget := maxf(RETARGET_DISTANCE, actor.position.distance_to(target.position) * RETARGET_FRACTION)
	if not actor.has_move_target or actor.move_target.distance_to(target.position) > retarget:
		actor.set_move_target(target.position)

## Whether an unleased actor is still partway through a door sequence, which
## it finishes before following anew.
func _keeps_to_plan(actor: ActorReference, plan: Dictionary) -> bool:
	if plan.is_empty() or plan["state"] != PLAN_READY:
		return false
	if actor.simulation_mode == ActorReference.SimulationMode.PHYSICAL_LEASED:
		return false
	return actor.current_space_form_id != plan["target_space"]

## Walks the planned doors toward a point in another space in order,
## activating each once there; plans the sequence first, on
## NpcSimulationServer's thread.
func _go_through_doors(actor: ActorReference, target_space: int, target_position: Vector3) -> void:
	var plan: Dictionary = _door_plans.get(actor, {})
	if _needs_plan(actor, target_space, plan):
		actor.clear_move_target()
		_request_plan(actor, target_space, target_position)
		return
	if plan["state"] != PLAN_READY:
		return
	var portals: Array = plan["portals"]
	var next: int = plan["next"]
	if next >= portals.size():
		_drop_plan(actor)
		return
	var portal = portals[next]
	if actor.current_space_form_id != portal.source_space_form_id:
		# Not where the sequence expected (a door that did not move it, or
		# something else moved it): plan again.
		_drop_plan(actor)
		return
	if not plan.has("walking"):
		plan["walking"] = true
		actor.set_move_target(portal.source_position)
		return
	if actor.has_move_target:
		return
	plan.erase("walking")
	plan["next"] = next + 1
	ScriptServer.activate(portal.source_reference, actor)

func _needs_plan(actor: ActorReference, target_space: int, plan: Dictionary) -> bool:
	if plan.is_empty():
		return true
	if plan["state"] == PLAN_FAILED:
		return plan["target_space"] != target_space or Time.get_ticks_msec() >= int(plan["retry_msec"])
	if plan["target_space"] == target_space:
		return false
	return not _keeps_to_plan(actor, plan) and plan["state"] != PLAN_PENDING

## Forgets `actor`'s door plan, cancelling its request if it is still being
## planned.
func _drop_plan(actor: ActorReference) -> void:
	var plan: Dictionary = _door_plans.get(actor, {})
	if not plan.is_empty() and plan["state"] == PLAN_PENDING:
		_actors_by_request.erase(plan["request_id"])
		get_parent().cancel_request(plan["request_id"])
	_door_plans.erase(actor)

func _request_plan(actor: ActorReference, target_space: int, target_position: Vector3) -> void:
	var server = get_parent()
	var request_id: int = server.request_door_sequence(actor.current_space_form_id, actor.position, target_space, target_position, server.blocked_doors_for(actor))
	_actors_by_request[request_id] = actor
	_door_plans[actor] = {"target_space": target_space, "state": PLAN_PENDING, "request_id": request_id}

func _on_door_sequence_ready(request_id: int, portals: Array) -> void:
	var actor: ActorReference = _actors_by_request.get(request_id)
	_actors_by_request.erase(request_id)
	if actor == null or not _door_plans.has(actor) or _door_plans[actor]["request_id"] != request_id:
		return
	var plan: Dictionary = _door_plans[actor]
	if portals.is_empty() or portals[0].source_reference == null:
		plan["state"] = PLAN_FAILED
		plan["retry_msec"] = Time.get_ticks_msec() + int(plan_retry_seconds * 1000.0)
		return
	plan["state"] = PLAN_READY
	plan["portals"] = portals
	plan["next"] = 0

## PTDT Target 1 as a reference: a specific reference (0x14 is the player) or
## the actor's linked reference (XLKR). Object ID and object type targets are
## not resolved yet.
func _target_1(actor: ActorReference, package: PackageBase) -> EsmReference:
	if not package.has_target_1:
		return null
	match package.target_1_type:
		PackageBase.TargetType.SPECIFIC_REFERENCE:
			if package.target_1_form_id == PackageBase.PLAYER_REFERENCE_FORM_ID:
				return ScriptServer.player_reference
			return EsmServer.get_reference("authored:%08X" % package.target_1_form_id)
		PackageBase.TargetType.LINKED_REFERENCE:
			if actor.linked_reference_form_id == 0:
				return null
			return EsmServer.get_reference("authored:%08X" % actor.linked_reference_form_id)
	return null

## Files an actor in the leased or the unleased sweep.
func _file(actor: ActorReference) -> void:
	if actor.simulation_mode == ActorReference.SimulationMode.PHYSICAL_LEASED:
		_unleased.remove(actor)
		_leased.add(actor)
		return
	_leased.remove(actor)
	_unleased.add(actor)

func _on_simulation_mode_changed(actor: ActorReference) -> void:
	_last_run_msec[actor] = Time.get_ticks_msec()
	travel.forget(actor)
	_file(actor)

## Seconds since `actor` last ran, at most two sweeps.
func _seconds_since_last_run(actor: ActorReference) -> float:
	var elapsed := (Time.get_ticks_msec() - int(_last_run_msec.get(actor, Time.get_ticks_msec()))) / 1000.0
	return minf(elapsed, unleased_sweep_seconds * 2.0)

## Actors visited in turn: each physics frame takes the share that visits
## every member once per `period` seconds, however many there are.
class Sweep:
	var period: float
	var _actors: Array[ActorReference] = []
	var _members: Dictionary = {}
	var _index := 0

	func _init(seconds: float) -> void:
		period = seconds

	func add(actor: ActorReference) -> void:
		if _members.has(actor):
			return
		_members[actor] = true
		_actors.append(actor)

	func remove(actor: ActorReference) -> void:
		if not _members.has(actor):
			return
		_members.erase(actor)
		_actors.erase(actor)

	func size() -> int:
		return _actors.size()

	## Where the sweep has got to, for diagnostics: wraps to 0 each full
	## pass.
	func get_index() -> int:
		return _index

	## This frame's share of the members.
	func take() -> Array[ActorReference]:
		var share: Array[ActorReference] = []
		if _actors.is_empty():
			return share
		var per_frame := ceili(_actors.size() / (period * Engine.physics_ticks_per_second))
		for step in mini(per_frame, _actors.size()):
			_index = _index % _actors.size()
			share.append(_actors[_index])
			_index += 1
		return share
