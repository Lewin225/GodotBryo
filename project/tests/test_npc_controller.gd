extends Node

## Walks Doc Mitchell across GSDocMitchellHouse with an NpcController: the
## route comes from NpcSimulationServer, the local path from the house's
## NavigationServer3D map, and the clip from his ActorMotion.

const NpcControllerScene := preload("res://GodotBryo/Types/Node/npc_controller.tscn")
const DOC_HOUSE_EDITOR_ID := "GSDocMitchellHouse"
## The farthest point Doc is sent to is at least this far away, metres.
const MINIMUM_WALK := 6.0
## Physics frames allowed for the walk.
const WALK_FRAMES := 60 * 60

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
	check(doc != null and doc.current_space_form_id == cell, "Doc is in %s" % DOC_HOUSE_EDITOR_ID)
	var start := doc.position
	var target := _far_point(cell, start)
	check(start.distance_to(target) >= MINIMUM_WALK, "a target %.1f m from Doc that NavmeshReader routes to" % start.distance_to(target))

	doc.simulation_mode = ActorReference.SimulationMode.PHYSICAL_LEASED
	var controller := NpcControllerScene.instantiate() as NpcController
	add_child(controller)
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
	check(not walk_clips.has("locomotion__male__mtbackward.kf") and not walk_clips.has("locomotion__male__mtleft.kf") and not walk_clips.has("locomotion__male__mtright.kf"), "Doc turns before walking: no backward or sideways clip")
	for frame in 30:
		await get_tree().physics_frame
	check(player != null and player.current_animation == "locomotion__mtidle.kf", "Doc idles after arriving (%s)" % (player.current_animation if player != null else "no player"))

	doc.simulation_mode = ActorReference.SimulationMode.LOW_LEVEL
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

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
