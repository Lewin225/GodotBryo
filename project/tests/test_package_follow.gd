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
	NpcSimulationServer.package_runner.set_script_package(doc, package)
	await _check_follows("across his house")

	var front_door := EsmServer.get_reference("authored:%08X" % FRONT_DOOR_FORM_ID) as DoorReference
	var wasteland := front_door.get_teleport_destination_space_form_id()
	_move_player(wasteland, front_door.teleport_position + Vector3(3.0, 0.0, 0.0))
	await _check_follows("out of the front door into WastelandNV")

	_move_player(house, far)
	await _check_follows("back into his house")
	_check_avoids_locked_door(wasteland)
	await _check_disabled_is_inert(house, package)

	check(not NpcSimulationServer.low_level_travel._is_running(doc), "%s walks: no Always Run flag" % FOLLOW_PACKAGE_EDITOR_ID)
	var running_package := EsmServer.find_base_by_editor_id(RUNNING_FOLLOW_PACKAGE_EDITOR_ID) as PackageBase
	NpcSimulationServer.package_runner.set_script_package(doc, running_package)
	await get_tree().physics_frame
	check(NpcSimulationServer.low_level_travel._is_running(doc), "%s runs: Always Run" % RUNNING_FOLLOW_PACKAGE_EDITOR_ID)

	var follow_package := doc.script_package
	NpcSimulationServer.package_runner.set_script_package(doc, null)
	await get_tree().physics_frame
	check(doc.script_package == null and doc.active_package != follow_package, "RemoveScriptPackage's path clears the script package, and Doc chooses from his own (%s)" % (doc.active_package.editor_id if doc.active_package != null else "none"))
	var reply: Dictionary = ScriptServer.run_debug_line("DebugAddScriptPackageAll %s" % FOLLOW_PACKAGE_EDITOR_ID)
	var actors: int = NpcSimulationServer.actors_by_instance_id.size()
	check(bool(reply.get("ok", false)) and int(reply.get("result", -1)) >= actors - 1 and doc.script_package != null, "DebugAddScriptPackageAll gives every placed actor the package (%s of %d)" % [reply.get("result"), actors])
	reply = ScriptServer.run_debug_line("DebugNpcLog 10")
	check(bool(reply.get("ok", false)) and NpcSimulationServer.debug_log.interval_seconds == 10.0 and NpcSimulationServer.debug_log._line().begins_with("at "), "DebugNpcLog switches the log on and a line builds: %s" % NpcSimulationServer.debug_log._line().left(90))
	check(NpcSimulationServer.debug_log._nif_line().begins_with("requests "), "and its NifServer line builds: %s" % NpcSimulationServer.debug_log._nif_line().left(90))
	ScriptServer.run_debug_line("DebugNpcLog 0")
	reply = ScriptServer.run_debug_line("DebugCopyBench")
	check(bool(reply.get("ok", false)), "DebugCopyBench runs")
	reply = ScriptServer.run_debug_line("DebugCopyBench 1")
	await get_tree().process_frame
	await get_tree().process_frame
	check(bool(reply.get("ok", false)) and not NifServer.run_in_next_drain.is_valid(), "DebugCopyBench 1 runs inside NifServer's drain")
	var split: PackedStringArray = load("res://scripting_debug_tab.gd").split_statements('DebugNpcLog 5 | DebugSetLowLevelSpeed 1000|| x | if a || b | MessageBox "a | b"')
	check(split == PackedStringArray(["DebugNpcLog 5", "DebugSetLowLevelSpeed 1000|| x", "if a || b", 'MessageBox "a | b"']), "the Script Engine console splits a line at | but not at || or inside quotes: %s" % split)
	ScriptServer.run_debug_line("DebugCopyBench 4")
	for frame in 95:
		await get_tree().process_frame
	reply = ScriptServer.run_debug_line("DebugSetLowLevelSpeed 3")
	check(bool(reply.get("ok", false)) and NpcSimulationServer.low_level_travel.speed_scale == 3.0, "DebugSetLowLevelSpeed sets the off-screen speed multiplier (was %s)" % reply.get("result"))
	NpcSimulationServer.low_level_travel.speed_scale = SPEED_SCALE
	reply = ScriptServer.run_debug_line("DebugRemoveScriptPackageAll")
	check(bool(reply.get("ok", false)) and doc.script_package == null, "DebugRemoveScriptPackageAll clears them (%s)" % reply.get("result"))
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

## A disabled actor keeps its package but is inert: it neither gets a target
## nor moves when the player walks away.
func _check_disabled_is_inert(house: int, package: PackageBase) -> void:
	NpcSimulationServer.package_runner.set_script_package(doc, package)
	doc.set_disabled(true)
	var resting_space := doc.current_space_form_id
	var resting := doc.position
	_move_player(house, _far_point(house, doc.position))
	for frame in 120:
		await get_tree().physics_frame
	check(not doc.has_move_target and doc.current_space_form_id == resting_space and doc.position.distance_to(resting) < 0.01, "a disabled Doc with a follow package stays put")
	doc.set_disabled(false)
	NpcSimulationServer.package_runner.set_script_package(doc, null)

## The Prospector Saloon has four load doors to WastelandNV; one (00108BC7)
## has lock data and no key. Sunny's door sequence out uses one of the others.
func _check_avoids_locked_door(wasteland: int) -> void:
	var sunny := EsmServer.find_reference_by_editor_id("SunnyRef") as ActorReference
	var front_door := EsmServer.get_reference("authored:%08X" % FRONT_DOOR_FORM_ID) as DoorReference
	var blocked: Dictionary = NpcSimulationServer.blocked_doors_for(sunny)
	var sequence: Dictionary = NpcSimulationServer.find_door_sequence(sunny.current_space_form_id, sunny.position, wasteland, front_door.teleport_position, blocked)
	var doors := []
	for portal in sequence["portals"]:
		doors.append(portal.source_reference.instance_id)
	var locked_door := EsmServer.get_reference("authored:00108BC7") as DoorReference
	check(blocked.has(locked_door) and bool(sequence["found"]) and not doors.has(locked_door.instance_id), "Sunny leaves the saloon by a door she can pass (%s), not the locked 00108BC7" % ", ".join(doors))

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
