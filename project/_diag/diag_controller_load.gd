extends Node3D

## Per-frame cost of many NpcControllers: ACTORS placed WastelandNV actors are
## moved to random navmesh points in the 7 x 7 cells around Goodsprings
## (-17, 0), physicalised as NpcControllers with the cells local navigation,
## and all follow the player (DefaultFollowPlayerClose) standing in the
## middle. Physics process
## time is averaged over FRAMES frames once they are walking.

const CENTER := Vector2i(-17, 0)
const RADIUS := 3
const FRAMES := 300
const ACTORS := 350

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	NpcSimulationServer.records_per_frame = 512
	NpcSimulationServer.seed()
	if not NpcSimulationServer.is_seeded:
		await NpcSimulationServer.seed_finished
	var wasteland := EsmServer.find_form_id_by_editor_id("WastelandNV")
	var cells := PackedInt32Array()
	var actors: Array[ActorReference] = []
	for dx in range(-RADIUS, RADIUS + 1):
		for dy in range(-RADIUS, RADIUS + 1):
			var cell := EsmServer.get_exterior_cell_form_id(wasteland, CENTER + Vector2i(dx, dy))
			if cell == 0:
				continue
			cells.append(cell)
	NpcSimulationServer.local_navigation.set_local_cells(wasteland, cells)
	var points := _navmesh_points(wasteland, cells)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for actor: ActorReference in NpcSimulationServer.get_actors_in_space(wasteland):
		if actors.size() >= ACTORS:
			break
		actors.append(actor)
		var spot: Vector3 = points[points.size() / 2] + Vector3(rng.randf_range(-2.0, 2.0), rng.randf_range(-2.0, 2.0), 0.0) if OS.get_cmdline_user_args().has("cluster") else points[rng.randi_range(0, points.size() - 1)]
		ScriptServer.move_reference(actor, wasteland, spot, Vector3.ZERO)
	ScriptServer.apply_pending_moves()
	var physicaliser := EsmReferencePhysicaliser.new()
	for actor in actors:
		physicaliser.physicalise(actor, self)
	var player := EsmServer.get_player_reference()
	ScriptServer.player_reference = player
	ScriptServer.move_reference(player, wasteland, points[points.size() / 2], Vector3.ZERO)
	ScriptServer.apply_pending_moves()
	for frame in 120:
		await get_tree().physics_frame
	# `-- cluster` piles every actor within 2 m of one point and gives them no
	# package, as a crowd left standing where it arrived.
	if not OS.get_cmdline_user_args().has("cluster"):
		var package := EsmServer.find_base_by_editor_id("DefaultFollowPlayerClose") as PackageBase
		for actor in actors:
			NpcSimulationServer.package_runner.set_package(actor, package)
	for frame in 120:
		await get_tree().physics_frame
	_inventory(self)
	# `-- strip_modifiers` frees every SkeletonModifier3D (physical bone
	# simulators, look targets) from the built actors.
	if OS.get_cmdline_user_args().has("strip_modifiers"):
		var stripped := 0
		for node in find_children("*", "SkeletonModifier3D", true, false):
			node.free()
			stripped += 1
		print("stripped %d skeleton modifiers" % stripped)
		for frame in 30:
			await get_tree().physics_frame
	# `-- bisect` measures, then removes one node category at a time from the
	# built actors (never the controller's own Body), measuring after each.
	if OS.get_cmdline_user_args().has("bisect"):
		await _bisect()
		get_tree().quit()
		return
	var process_total := 0.0
	var physics_total := 0.0
	var moving := 0
	for frame in FRAMES:
		await get_tree().physics_frame
		physics_total += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		process_total += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	for actor in actors:
		if actor.has_move_target:
			moving += 1
	print("%d controllers (%d still walking): physics process %.2f ms, process %.2f ms a frame" % [actors.size(), moving, physics_total / FRAMES, process_total / FRAMES])
	for actor in actors:
		NpcSimulationServer.package_runner.set_package(actor, null)
	get_tree().quit()

## Triangle centres of the cells' NAVM, Gamebryo axes.
func _navmesh_points(space: int, cells: PackedInt32Array) -> Array:
	var navmesh := NpcSimulationServer.navmesh
	var points := []
	for record in navmesh.get_records_in_space(space):
		if not cells.has(int(navmesh.get_record_info(record)["cell_form_id"])):
			continue
		var triangles: PackedVector3Array = navmesh.get_record_triangle_points(record)
		for first in range(0, triangles.size(), 3):
			points.append((triangles[first] + triangles[first + 1] + triangles[first + 2]) / 3.0)
	return points

## One built actor's nodes: how many of each class, and which process,
## internally process, or physics process every frame. Also the collision
## layers and masks of its bodies.
func _inventory(root: Node) -> void:
	var controller: NpcController = null
	for node in root.find_children("*", "NpcController", true, false):
		if (node as NpcController).actor != null and (node as NpcController).actor.is_visual_built():
			controller = node
			break
	if controller == null:
		print("no built actor to inventory")
		return
	var classes := {}
	var processing := {}
	for node in controller.find_children("*", "", true, false):
		var kind := node.get_class()
		classes[kind] = int(classes.get(kind, 0)) + 1
		var flags := []
		if node.is_processing():
			flags.append("process")
		if node.is_processing_internal():
			flags.append("internal")
		if node.is_physics_processing():
			flags.append("physics")
		if node.is_physics_processing_internal():
			flags.append("physics internal")
		if not flags.is_empty():
			var key := "%s [%s]" % [kind, ", ".join(flags)]
			processing[key] = int(processing.get(key, 0)) + 1
		if node is CollisionObject3D:
			var body := node as CollisionObject3D
			var key2 := "%s layer %d mask %d" % [kind, body.collision_layer, body.collision_mask]
			processing[key2] = int(processing.get(key2, 0)) + 1
	print("nodes under one built actor: %s" % classes)
	print("processing each frame / collision: %s" % processing)

func _bisect() -> void:
	print("bisect: all present: process %.1f ms" % await _mean_process())
	var stages := [["PhysicalBoneSimulator3D"], ["LookAtModifier3D"], ["AnimationPlayer"], ["BoneAttachment3D"], ["Skeleton3D"]]
	for stage: Array in stages:
		var removed := 0
		for kind: String in stage:
			for controller in find_children("*", "NpcController", true, false):
				var actor_node := (controller as NpcController).actor
				if actor_node == null:
					continue
				for node in actor_node.find_children("*", kind, true, false):
					if is_instance_valid(node):
						node.free()
						removed += 1
		print("bisect: removed %s (%d nodes): process %.1f ms" % [", ".join(stage), removed, await _mean_process()])

func _mean_process() -> float:
	for frame in 120:
		await get_tree().process_frame
	var total := 0.0
	for frame in 60:
		await get_tree().process_frame
		total += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	return total / 60.0
