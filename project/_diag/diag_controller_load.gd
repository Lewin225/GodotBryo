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
		ScriptServer.move_reference(actor, wasteland, points[rng.randi_range(0, points.size() - 1)], Vector3.ZERO)
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
	var package := EsmServer.find_base_by_editor_id("DefaultFollowPlayerClose") as PackageBase
	for actor in actors:
		NpcSimulationServer.package_runner.set_package(actor, package)
	for frame in 120:
		await get_tree().physics_frame
	var physics_total := 0.0
	var moving := 0
	for frame in FRAMES:
		await get_tree().physics_frame
		physics_total += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	for actor in actors:
		if actor.has_move_target:
			moving += 1
	print("%d controllers (%d still walking): physics process %.2f ms a frame" % [actors.size(), moving, physics_total / FRAMES])
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
