extends Node

## Doc Mitchell runs DefaultFollowPlayerClose (FOLLOW, the player, 128 units):
## NpcSimulationServer's PackageRunner sets his move_target and LowLevelTravel
## moves him, so he follows the player across his house, out through its front
## door into WastelandNV, and back in.

const FOLLOW_PACKAGE_EDITOR_ID := "DefaultFollowPlayerClose"
## A companion's follow package, with Always Run.
const RUNNING_FOLLOW_PACKAGE_EDITOR_ID := "FollowersBooneFollowPlayerDEFAULT"
const DOC_HOUSE_EDITOR_ID := "GSDocMitchellHouse"
## GSDocMitchellHouse's load door to WastelandNV.
const FRONT_DOOR_FORM_ID := 0x00103E61
## Doc travels this many times faster than authored, so each leg takes
## seconds.
const SPEED_SCALE := 10.0
## Physics frames allowed for each leg.
const LEG_FRAMES := 20 * 60
## How far past the package's follow distance Doc may stop, metres.
const TOLERANCE := 0.6

var failures := 0
var doc: ActorReference
var player: ActorReference
var follow_distance := 0.0

func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	NpcSimulationServer.records_per_frame = 512
	NpcSimulationServer.seed()
	if not NpcSimulationServer.is_seeded:
		await NpcSimulationServer.seed_finished
	NpcSimulationServer.low_level_travel.speed_scale = SPEED_SCALE
	player = EsmServer.get_player_reference()
	ScriptServer.player_reference = player
	doc = EsmServer.find_reference_by_editor_id("DocMitchellREF") as ActorReference
	var house := EsmServer.find_form_id_by_editor_id(DOC_HOUSE_EDITOR_ID)
	var package := EsmServer.find_base_by_editor_id(FOLLOW_PACKAGE_EDITOR_ID) as PackageBase
	check(package != null and package.package_type == PackageBase.PackageType.FOLLOW, "%s is a FOLLOW package" % FOLLOW_PACKAGE_EDITOR_ID)
	follow_distance = package.target_1_count_or_distance * PackageRunner.UNITS_TO_METERS

	var far := _far_point(house, doc.position)
	_move_player(house, far)
	NpcSimulationServer.package_runner.set_package(doc, package)
	await _check_follows("across his house")

	var front_door := EsmServer.get_reference("authored:%08X" % FRONT_DOOR_FORM_ID) as DoorReference
	var wasteland := front_door.get_teleport_destination_space_form_id()
	_move_player(wasteland, front_door.teleport_position + Vector3(3.0, 0.0, 0.0))
	await _check_follows("out of the front door into WastelandNV")

	_move_player(house, far)
	await _check_follows("back into his house")

	check(not doc.move_running, "%s walks: no Always Run flag" % FOLLOW_PACKAGE_EDITOR_ID)
	var running_package := EsmServer.find_base_by_editor_id(RUNNING_FOLLOW_PACKAGE_EDITOR_ID) as PackageBase
	NpcSimulationServer.package_runner.set_package(doc, running_package)
	await get_tree().physics_frame
	check(doc.move_running, "%s runs: Always Run" % RUNNING_FOLLOW_PACKAGE_EDITOR_ID)

	NpcSimulationServer.package_runner.set_package(doc, null)
	check(doc.active_package == null and not doc.has_move_target and not doc.move_running, "RemoveScriptPackage's path clears the package, the target and running")
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

func _move_player(space: int, position: Vector3) -> void:
	ScriptServer.move_reference(player, space, position, Vector3.ZERO)
	ScriptServer.apply_pending_moves()

## Waits until Doc is in the player's space within the follow distance and has
## stopped.
func _check_follows(label: String) -> void:
	var frames := 0
	while frames < LEG_FRAMES:
		await get_tree().physics_frame
		frames += 1
		if _caught_up():
			break
	var gap := doc.position.distance_to(player.position) if doc.current_space_form_id == player.current_space_form_id else INF
	check(_caught_up(), "Doc follows %s: %.2f m from the player after %.1f s" % [label, gap, frames / 60.0])

func _caught_up() -> bool:
	if doc.current_space_form_id != player.current_space_form_id or doc.has_move_target:
		return false
	return doc.position.distance_to(player.position) <= follow_distance + TOLERANCE

## The triangle centre in `space`'s NAVM farthest from `from` that
## NavmeshReader routes to.
func _far_point(space: int, from: Vector3) -> Vector3:
	var navmesh := NpcSimulationServer.navmesh
	var candidates := []
	for record in navmesh.get_records_in_space(space):
		var points: PackedVector3Array = navmesh.get_record_triangle_points(record)
		for first in range(0, points.size(), 3):
			candidates.append((points[first] + points[first + 1] + points[first + 2]) / 3.0)
	candidates.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.distance_to(from) > b.distance_to(from))
	for candidate: Vector3 in candidates:
		if bool(NpcSimulationServer.route(space, from, candidate).get("found", false)):
			return candidate
	return from
