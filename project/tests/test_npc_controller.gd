extends Node

## Walks Doc Mitchell across GSDocMitchellHouse with an NpcController: the
## route comes from NpcSimulationServer, the local path from the house's
## NavigationServer3D map, and the clip from his ActorMotion.

const NpcControllerScene := preload("res://GodotBryo/Types/Node/npc_controller.tscn")
const DOC_HOUSE_EDITOR_ID := "GSDocMitchellHouse"
## The farthest point Doc is sent to is at least this far away, metres.
const MINIMUM_WALK := 6.0
## Doc walks this many times faster than authored, so the walks take seconds.
const SPEED_SCALE := 5.0
## Physics frames allowed for each walk.
const WALK_FRAMES := 20 * 60

var failures := 0

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
	var cell := EsmServer.find_form_id_by_editor_id(DOC_HOUSE_EDITOR_ID)
	var local_navigation := NpcSimulationServer.local_navigation
	local_navigation.set_local_cells(cell, PackedInt32Array([cell]))
	if not local_navigation.is_cell_ready(cell):
		await local_navigation.cell_ready

	var doc := EsmServer.find_reference_by_editor_id("DocMitchellREF") as ActorReference
	# The test sets Doc's move_target itself; his own packages would set it too.
	NpcSimulationServer.package_runner.untrack(doc)
	check(doc != null and doc.current_space_form_id == cell, "Doc is in %s" % DOC_HOUSE_EDITOR_ID)
	var start := doc.position
	var target := _far_point(cell, start)
	check(start.distance_to(target) >= MINIMUM_WALK, "a target %.1f m from Doc that NavmeshReader routes to" % start.distance_to(target))

	doc.simulation_mode = ActorReference.SimulationMode.PHYSICAL_LEASED
	var controller := NpcControllerScene.instantiate() as NpcController
	add_child(controller)
	controller.speed_scale = SPEED_SCALE
	controller.reference = doc
	var clips := [-1]
	controller.actor.animation_load_completed.connect(func(count: int) -> void: clips[0] = count)
	for frame in 3000:
		if clips[0] >= 0:
			break
		await get_tree().process_frame
	check(clips[0] > 0, "Doc's locomotion clips load (%d)" % clips[0])
	var player := controller.find_child("LocomotionAnimationPlayer", true, false) as AnimationPlayer

	var reached := [false]
	doc.move_target_reached.connect(func() -> void: reached[0] = true)
	doc.set_move_target(target)
	var walk_clips := {}
	var frames := 0
	while not reached[0] and frames < WALK_FRAMES:
		await get_tree().physics_frame
		frames += 1
		if player != null and player.current_animation != "":
			walk_clips[player.current_animation] = true
	check(reached[0], "Doc reaches the target in %.1f s" % (frames / 60.0))
	check(not doc.has_move_target, "the target is cleared on arrival")
	check(_planar(doc.position).distance_to(_planar(target)) < 0.6, "Doc's reference is at the target (%.2f m off)" % _planar(doc.position).distance_to(_planar(target)))
	check(walk_clips.has("locomotion__male__mtforward.kf"), "the walk clip played on the way (%s)" % ", ".join(walk_clips.keys()))
	await get_tree().physics_frame
	var body_transform: Transform3D = PhysicsServer3D.body_get_state(controller.body.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM)
	var capsule_offset := body_transform.origin.distance_to(controller.body.global_position)
	check(capsule_offset < 0.05, "the physics server's capsule walked with Doc (%.2f m from his body node)" % capsule_offset)
	check(not walk_clips.has("locomotion__male__mtbackward.kf") and not walk_clips.has("locomotion__male__mtleft.kf") and not walk_clips.has("locomotion__male__mtright.kf"), "Doc turns before walking: no backward or sideways clip")
	for frame in 30:
		await get_tree().physics_frame
	check(player != null and player.current_animation == "locomotion__mtidle.kf", "Doc idles after arriving (%s)" % (player.current_animation if player != null else "no player"))

	_check_avoidance_follows_enable_state(controller, doc)
	await _check_seam_crossing(controller, doc)
	await _check_stuck_recovery(controller, doc)
	_check_running_follows_package(controller, doc)
	doc.simulation_mode = ActorReference.SimulationMode.LOW_LEVEL
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

## A disabled actor is hidden; its agent must not steer others either.
## The controller runs while the active package has Always Run, read when
## active_package_changed fires.
func _check_running_follows_package(controller: NpcController, doc: ActorReference) -> void:
	var previous := doc.active_package
	var running := PackageBase.new()
	running.general_flags = PackageBase.GENERAL_FLAG_ALWAYS_RUN
	doc.active_package = running
	var runs := controller.get_speed()
	doc.active_package = PackageBase.new()
	var walks := controller.get_speed()
	doc.active_package = previous
	check(runs > walks, "the controller runs under an Always Run package and walks otherwise (%.2f against %.2f m/s)" % [runs, walks])

func _check_avoidance_follows_enable_state(controller: NpcController, doc: ActorReference) -> void:
	check(controller.agent.avoidance_enabled, "a leased, enabled Doc takes part in avoidance")
	doc.set_disabled(true)
	check(not controller.agent.avoidance_enabled, "disabled, he does not")
	doc.set_disabled(false)
	check(controller.agent.avoidance_enabled, "enabled again, he does")

## Interior 0x10D629's NAVM records meet at seams 1.12-3.84 m wide, which
## only LocalNavigation's seam links join: Doc walks from beside a seam across
## it into the other record.
func _check_seam_crossing(controller: NpcController, doc: ActorReference) -> void:
	var cell := 0x10D629
	var navmesh := NpcSimulationServer.navmesh
	var local_navigation := NpcSimulationServer.local_navigation
	local_navigation.set_local_cells(cell, PackedInt32Array([cell]))
	if not local_navigation.is_cell_ready(cell):
		await local_navigation.cell_ready
	var records: PackedInt32Array = navmesh.get_records_in_space(cell)
	var seam: Dictionary = navmesh.get_record_seam_links(records[0], LocalNavigation.EDGE_CONNECTION_MARGIN, LocalNavigation.MAX_SEAM_LINK_GAP)
	var seam_points: PackedVector3Array = seam["points"]
	var far_record: int = seam["target_records"][0]
	var start := _nearest_centre(navmesh, records[0], seam_points[0], false)
	var target := _nearest_centre(navmesh, far_record, seam_points[1], false)
	check(bool(NpcSimulationServer.route(cell, start, target).get("found", false)), "NavmeshReader routes across a seam of 0x%X (%.1f m)" % [cell, start.distance_to(target)])
	ScriptServer.move_reference(doc, cell, start, doc.rotation)
	ScriptServer.apply_pending_moves()
	await get_tree().physics_frame
	var reached := [false]
	var on_reached := func() -> void: reached[0] = true
	doc.move_target_reached.connect(on_reached)
	var links_crossed := [0]
	var on_link := func(_details: Dictionary) -> void: links_crossed[0] += 1
	controller.agent.link_reached.connect(on_link)
	doc.set_move_target(target)
	var frames := 0
	while not reached[0] and frames < WALK_FRAMES:
		await get_tree().physics_frame
		frames += 1
	doc.move_target_reached.disconnect(on_reached)
	controller.agent.link_reached.disconnect(on_link)
	check(links_crossed[0] > 0, "his path crosses a seam link (%d)" % links_crossed[0])
	check(reached[0], "Doc crosses the seam and arrives in %.1f s (%.2f m off)" % [frames / 60.0, _planar(doc.position).distance_to(_planar(target))])

## A Doc who cannot move (speed 0) is stuck: after `stuck_seconds` he is moved
## to each waypoint in turn and arrives.
func _check_stuck_recovery(controller: NpcController, doc: ActorReference) -> void:
	var start := doc.position
	var target := _far_point(doc.current_space_form_id, start)
	controller.speed_scale = 0.0
	controller.stuck_seconds = 0.25
	var reached := [false]
	var on_reached := func() -> void: reached[0] = true
	doc.move_target_reached.connect(on_reached)
	doc.set_move_target(target)
	var frames := 0
	while not reached[0] and frames < WALK_FRAMES:
		await get_tree().physics_frame
		frames += 1
	doc.move_target_reached.disconnect(on_reached)
	check(reached[0], "a Doc who cannot move is moved along his route and arrives (%.1f m in %.1f s)" % [start.distance_to(target), frames / 60.0])
	controller.speed_scale = SPEED_SCALE
	controller.stuck_seconds = 3.0

## The triangle centre of `record` nearest `point` (Gamebryo axes, as
## NavmeshReader gives it), or farthest from it.
func _nearest_centre(navmesh: NavmeshReader, record: int, point: Vector3, farthest: bool) -> Vector3:
	var points: PackedVector3Array = navmesh.get_record_triangle_points(record)
	var best := Vector3.ZERO
	var best_distance := INF
	for first in range(0, points.size(), 3):
		var centre := (points[first] + points[first + 1] + points[first + 2]) / 3.0
		var distance := centre.distance_to(point)
		if farthest:
			distance = -distance
		if distance < best_distance:
			best_distance = distance
			best = centre
	return best

## The triangle centre in `cell`'s NAVM farthest from `from` that
## NavmeshReader finds a route to.
func _far_point(cell: int, from: Vector3) -> Vector3:
	var navmesh := NpcSimulationServer.navmesh
	var candidates := []
	for record in navmesh.get_records_in_space(cell):
		var points: PackedVector3Array = navmesh.get_record_triangle_points(record)
		for first in range(0, points.size(), 3):
			var centre := (points[first] + points[first + 1] + points[first + 2]) / 3.0
			candidates.append(centre)
	candidates.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.distance_to(from) > b.distance_to(from))
	for candidate: Vector3 in candidates:
		if bool(NpcSimulationServer.route(cell, from, candidate).get("found", false)):
			return candidate
	return from

func _planar(point: Vector3) -> Vector2:
	return Vector2(point.x, point.y)
