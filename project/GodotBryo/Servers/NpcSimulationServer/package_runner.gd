class_name PackageRunner
extends Node

## Runs actors' active packages, for actors on screen and off alike: it
## decides where an actor goes (`ActorReference.move_target`) and NpcController
## or LowLevelTravel moves it there. Only actors given a package through
## `set_package()` (AddScriptPackage) run; package selection from the base's
## packages is not implemented yet.
##
## Budget (README "Tick rates"): leased actors run every physics frame; the
## others in a round-robin sweep that visits each once per
## `unleased_sweep_seconds`, however many there are, and LowLevelTravel moves
## each on its turn by the time since its last.
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

enum { PLAN_PENDING, PLAN_READY, PLAN_FAILED }

## PTDT Count / Distance is in Gamebryo units (common/units.h).
const UNITS_TO_METERS := 1.0 / 70.0
## A follower is sent toward its target again once the target has moved this
## far from where it was sent, metres.
const RETARGET_DISTANCE := 1.0

## Every unleased actor with a package runs once per this many seconds.
@export var unleased_sweep_seconds := 1.0
## A route between spaces that was not found is planned again after this many
## seconds, unless the target changes space first.
@export var plan_retry_seconds := 10.0

## Unleased actors with a package, in sweep order, and as a set.
var _sweep: Array[ActorReference] = []
var _in_sweep: Dictionary = {}
var _sweep_index := 0
## Leased actors with a package, run every frame.
var _leased: Dictionary = {}
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

var travel: LowLevelTravel:
	get:
		return get_parent().get_node_or_null(^"LowLevelTravel") as LowLevelTravel

func _ready() -> void:
	get_parent().door_sequence_ready.connect(_on_door_sequence_ready)

## Gives `actor` `package` as its active package (AddScriptPackage), or clears
## it with null (RemoveScriptPackage).
func set_package(actor: ActorReference, package: PackageBase) -> void:
	actor.active_package = package
	_door_plans.erase(actor)
	if package == null:
		_forget(actor)
		actor.clear_move_target()
		actor.move_running = false
		return
	if _mode_handlers.has(actor):
		return
	_last_run_msec[actor] = Time.get_ticks_msec()
	var handler := _on_simulation_mode_changed.bind(actor)
	_mode_handlers[actor] = handler
	actor.simulation_mode_changed.connect(handler)
	_file(actor)

## Debug: gives `package` (null clears it) to every actor NpcSimulationServer
## tracks, the player excepted. Returns how many actors it set.
func set_package_for_all(package: PackageBase) -> int:
	var count := 0
	for actor: ActorReference in get_parent().actors_by_instance_id.values():
		if actor == ScriptServer.player_reference:
			continue
		set_package(actor, package)
		count += 1
	return count

func _physics_process(_delta: float) -> void:
	for actor: ActorReference in _leased.keys():
		_run(actor)
	if _sweep.is_empty():
		return
	var per_frame := ceili(_sweep.size() / (unleased_sweep_seconds * Engine.physics_ticks_per_second))
	for step in mini(per_frame, _sweep.size()):
		_sweep_index = _sweep_index % _sweep.size()
		var actor := _sweep[_sweep_index]
		_sweep_index += 1
		var elapsed := _seconds_since_last_run(actor)
		_run(actor)
		travel.advance(actor, elapsed)

## One run of an actor's package.
func _run(actor: ActorReference) -> void:
	_last_run_msec[actor] = Time.get_ticks_msec()
	var package := actor.active_package
	if actor.is_disabled() or package == null:
		return
	actor.move_running = (package.general_flags & PackageBase.GENERAL_FLAG_ALWAYS_RUN) != 0
	match package.package_type:
		PackageBase.PackageType.FOLLOW:
			_follow(actor, package)

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
	_door_plans.erase(actor)
	var distance := float(package.target_1_count_or_distance) * UNITS_TO_METERS
	if actor.position.distance_to(target.position) <= distance:
		if actor.has_move_target:
			actor.clear_move_target()
		return
	if not actor.has_move_target or actor.move_target.distance_to(target.position) > RETARGET_DISTANCE:
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
		_door_plans.erase(actor)
		return
	var portal = portals[next]
	if actor.current_space_form_id != portal.source_space_form_id:
		# Not where the sequence expected (a door that did not move it, or
		# something else moved it): plan again.
		_door_plans.erase(actor)
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

## Files an actor as leased (every frame) or unleased (the sweep).
func _file(actor: ActorReference) -> void:
	if actor.simulation_mode == ActorReference.SimulationMode.PHYSICAL_LEASED:
		_leave_sweep(actor)
		_leased[actor] = true
		return
	_leased.erase(actor)
	if not _in_sweep.has(actor):
		_in_sweep[actor] = true
		_sweep.append(actor)

func _leave_sweep(actor: ActorReference) -> void:
	if _in_sweep.has(actor):
		_in_sweep.erase(actor)
		_sweep.erase(actor)

func _on_simulation_mode_changed(actor: ActorReference) -> void:
	_last_run_msec[actor] = Time.get_ticks_msec()
	travel.forget(actor)
	_file(actor)

func _forget(actor: ActorReference) -> void:
	if _mode_handlers.has(actor):
		actor.simulation_mode_changed.disconnect(_mode_handlers[actor])
		_mode_handlers.erase(actor)
	_leased.erase(actor)
	_leave_sweep(actor)
	_last_run_msec.erase(actor)
	travel.forget(actor)

## Seconds since `actor` last ran, at most two sweeps.
func _seconds_since_last_run(actor: ActorReference) -> float:
	var elapsed := (Time.get_ticks_msec() - int(_last_run_msec.get(actor, Time.get_ticks_msec()))) / 1000.0
	return minf(elapsed, unleased_sweep_seconds * 2.0)
