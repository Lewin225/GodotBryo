class_name PackageRunner
extends Node

## Runs actors' active packages every physics frame, for actors on screen and
## off alike: it decides where an actor goes (`ActorReference.move_target`) and
## NpcController or LowLevelTravel moves it there. Only actors given a package
## through `set_package()` (AddScriptPackage) run; package selection from the
## base's packages is not implemented yet.
##
## Implemented package types: FOLLOW. Others leave the actor where it is. The
## Always Run flag makes the actor run wherever it moves.

## PTDT Count / Distance is in Gamebryo units (common/units.h).
const UNITS_TO_METERS := 1.0 / 70.0
## A follower is sent toward its target again once the target has moved this
## far from where it was sent, metres.
const RETARGET_DISTANCE := 1.0

## ActorReference -> true for every actor running a package.
var _actors: Dictionary = {}
## ActorReference -> the door it is walking to on its way to a target in
## another space: {"door": DoorReference, "target_space": int}.
var _door_plans: Dictionary = {}

var travel: LowLevelTravel:
	get:
		return get_parent().get_node_or_null(^"LowLevelTravel") as LowLevelTravel

## Gives `actor` `package` as its active package (AddScriptPackage), or clears
## it with null (RemoveScriptPackage).
func set_package(actor: ActorReference, package: PackageBase) -> void:
	actor.active_package = package
	_door_plans.erase(actor)
	if package == null:
		_actors.erase(actor)
		travel.untrack(actor)
		actor.clear_move_target()
		actor.move_running = false
		return
	_actors[actor] = true
	travel.track(actor)

func _physics_process(_delta: float) -> void:
	for actor: ActorReference in _actors.keys():
		if actor.is_disabled() or actor.active_package == null:
			continue
		actor.move_running = (actor.active_package.general_flags & PackageBase.GENERAL_FLAG_ALWAYS_RUN) != 0
		match actor.active_package.package_type:
			PackageBase.PackageType.FOLLOW:
				_follow(actor, actor.active_package)

## Follow: stays within the package's Count / Distance of Target 1, going
## through load doors when the target is in another space.
func _follow(actor: ActorReference, package: PackageBase) -> void:
	var target := _target_1(actor, package)
	if target == null or target.current_space_form_id == 0:
		actor.clear_move_target()
		return
	if target.current_space_form_id != actor.current_space_form_id:
		_follow_through_door(actor, target)
		return
	_door_plans.erase(actor)
	var distance := float(package.target_1_count_or_distance) * UNITS_TO_METERS
	if actor.position.distance_to(target.position) <= distance:
		if actor.has_move_target:
			actor.clear_move_target()
		return
	if not actor.has_move_target or actor.move_target.distance_to(target.position) > RETARGET_DISTANCE:
		actor.set_move_target(target.position)

## Walks to the first load door on a route to `target`'s space and activates
## it once there, which moves the actor to the door's destination.
func _follow_through_door(actor: ActorReference, target: EsmReference) -> void:
	var plan: Dictionary = _door_plans.get(actor, {})
	if plan.is_empty() or plan["target_space"] != target.current_space_form_id:
		plan = _plan_door(actor, target)
		if plan.is_empty():
			actor.clear_move_target()
			return
		_door_plans[actor] = plan
		actor.set_move_target((plan["door"] as DoorReference).position)
		return
	if actor.has_move_target:
		return
	_door_plans.erase(actor)
	ScriptServer.activate(plan["door"], actor)

## The first door of a route from `actor` to `target` in another space; empty
## when there is none.
func _plan_door(actor: ActorReference, target: EsmReference) -> Dictionary:
	var route: Dictionary = get_parent().route_across_spaces(actor.current_space_form_id, actor.position, target.current_space_form_id, target.position)
	if not bool(route.get("found", false)) or route["legs"].is_empty():
		return {}
	var portal = route["legs"][0]["exit_portal"]
	if portal == null or portal.source_reference == null:
		return {}
	return {"door": portal.source_reference, "target_space": target.current_space_form_id}

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
