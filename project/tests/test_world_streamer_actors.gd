extends Node3D

## WorldStreamerV2 physicalises a tile's actors from NpcSimulationServer: a
## persistent actor (Easy Pete, filed in WastelandNV's persistent CELL, sitting
## in Goodsprings) gets a node under the tile he stands in, even when streaming
## starts before NpcSimulationServer has seeded.

const WASTELAND_NV := 0x000DA726

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
	var pete := EsmServer.find_reference_by_editor_id("EasyPeteRef") as ActorReference
	check(pete != null and pete.current_space_form_id == WASTELAND_NV, "EasyPeteRef is in WastelandNV")

	var camera := Camera3D.new()
	add_child(camera)
	camera.global_position = EsmReferencePhysicaliser.GAMEBRYO_TO_GODOT_BASIS * pete.position + Vector3.UP * 1.6
	camera.make_current()
	var streamer := WorldStreamerV2.new()
	streamer.load_radius = 1.0
	streamer.lod_load_radius = 1.0
	add_child(streamer)
	streamer.activate(WASTELAND_NV)
	for frame in 30:
		await get_tree().process_frame
	check(not NpcSimulationServer.is_seeded and EsmNode.node_for(pete) == null, "before NpcSimulationServer seeds, his tile has no actors")

	NpcSimulationServer.seed()
	if not NpcSimulationServer.is_seeded:
		await NpcSimulationServer.seed_finished
	await _wait_until(func() -> bool: return EsmNode.node_for(pete) != null)
	var node := EsmNode.node_for(pete)
	check(node != null and streamer.is_ancestor_of(node), "once it has, Easy Pete gets a node from the streamer")
	var tile := streamer._tile_root_for(pete)
	check(node != null and node.get_parent() == tile, "under the tile he stands in (%s)" % (node.get_parent().name if node != null else "none"))
	check(_count_placed_for(streamer, pete) == 1, "and placed only once (%d)" % _count_placed_for(streamer, pete))

	# An actor walking out of an interior while the player is still inside:
	# the streamer is paused when she arrives, and shows her on resuming.
	var sunny := EsmServer.find_reference_by_editor_id("SunnyRef") as ActorReference
	streamer.set_paused(true)
	sunny.set_location(WASTELAND_NV, pete.position + Vector3(2.0, 0.0, 0.0))
	for frame in 10:
		await get_tree().process_frame
	streamer.set_paused(false)
	await _wait_until(func() -> bool: return EsmNode.node_for(sunny) != null)
	var sunny_node := EsmNode.node_for(sunny)
	check(sunny_node != null and sunny_node.get_parent() == streamer._tile_root_for(sunny), "Sunny, arriving from her interior while the streamer is paused, has a node under her tile once it resumes (%s)" % (sunny_node.get_parent().name if sunny_node != null else "none"))
	check(NpcSimulationServer.get_actors_in_cell(sunny.current_cell_form_id).has(sunny), "and NpcSimulationServer lists her in that CELL")

	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)

func _wait_until(condition: Callable, frames := 1200) -> void:
	for frame in frames:
		if condition.call():
			return
		await get_tree().process_frame

## How many tile roots (or the persistent root's tiles) hold a node for
## `reference` as a direct child; an actor's body under its controller is not a
## second placement.
func _count_placed_for(streamer: WorldStreamerV2, reference: EsmReference) -> int:
	var count := 0
	var roots: Array[Node] = []
	for root in streamer.get_children():
		roots.append(root)
	if streamer._persistent_root != null:
		roots.append_array(streamer._persistent_root.get_children())
	for root in roots:
		for child in root.get_children():
			if child is EsmNode and child.reference == reference:
				count += 1
	return count
