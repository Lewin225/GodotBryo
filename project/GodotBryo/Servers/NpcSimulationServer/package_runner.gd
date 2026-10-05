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
## Implemented package types: FOLLOW. Others leave the actor where it is. The
## Always Run flag makes the actor run wherever it moves.
##
## Schedules (PSDT; over FalloutNV.esm's 4,163 PACK, month is always Any and date
## always 0): a package with an hour is due from it for its duration in hours,
## wrapping past midnight, so a duration of 0 is never due; one without an hour
## is always due, whatever its duration. Day of week (set on 53 packages, none of
## VCG01's) is not checked yet. With no game clock, only packages without an hour
## are due.

enum { PLAN_PENDING, PLAN_READY, PLAN_FAILED }

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

## Gives `actor` `package` as its script package (AddScriptPackage), or clears
## it with null (RemoveScriptPackage); either way the actor chooses again at once.
func set_script_package(actor: ActorReference, package: PackageBase) -> void:
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
	match package.package_type:
		PackageBase.PackageType.FOLLOW:
			_follow(actor, package)

## Chooses `actor`'s package; a different one replaces the old one's plan and
## target.
func _evaluate(actor: ActorReference) -> void:
	_next_evaluation_msec[actor] = Time.get_ticks_msec() + int(evaluation_seconds * 1000.0)
	var chosen := choose_package(actor)
	if chosen == actor.active_package:
		return
	actor.active_package = chosen
	_drop_plan(actor)
	travel.forget(actor)
	actor.clear_move_target()

## Follow: stays within the package's Count / Distance of Target 1, going
## through load doors when the target is in another space.
func _follow(actor: ActorReference, package: PackageBase) -> void:
	var target := _target_1(actor, package)
	if target == null or target.current_space_form_id == 0:
		actor.clear_move_target()
		return
	var plan: Dictionary = _door_plans.get(actor, {})
	if target.current_space_form_id != actor.current_space_form_id or _keeps_to_plan(actor, plan):
		_follow_through_doors(actor, target)
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

## Walks the planned doors in order, activating each once there; plans the
## sequence first, on NpcSimulationServer's thread.
func _follow_through_doors(actor: ActorReference, target: EsmReference) -> void:
	var plan: Dictionary = _door_plans.get(actor, {})
	if _needs_plan(actor, target, plan):
		actor.clear_move_target()
		_request_plan(actor, target)
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

func _needs_plan(actor: ActorReference, target: EsmReference, plan: Dictionary) -> bool:
	if plan.is_empty():
		return true
	if plan["state"] == PLAN_FAILED:
		return plan["target_space"] != target.current_space_form_id or Time.get_ticks_msec() >= int(plan["retry_msec"])
	if plan["target_space"] == target.current_space_form_id:
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

func _request_plan(actor: ActorReference, target: EsmReference) -> void:
	var server = get_parent()
	var request_id: int = server.request_door_sequence(actor.current_space_form_id, actor.position, target.current_space_form_id, target.position, server.blocked_doors_for(actor))
	_actors_by_request[request_id] = actor
	_door_plans[actor] = {"target_space": target.current_space_form_id, "state": PLAN_PENDING, "request_id": request_id}

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
