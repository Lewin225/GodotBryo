extends Node

## Reproduces Sunny Smiles walking out of her interior at VCG02 stage 10 with
## the player following, in game.tscn, and logs her reference, node and the
## streamers' state through it; then `player.moveto SunnyRef`.

const TIMEOUT_MSEC := 120000

var game: Node3D
var sunny: ActorReference
var _last_state := ""

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	game = (load("res://game.tscn") as PackedScene).instantiate()
	add_child(game)
	var coordinator: TransitionCoordinator = game.transition_coordinator
	var house := int(EsmServer.reader.find_cell_by_editor_id("GSDocMitchellHouse").get("form_id", 0))
	await _await_space(coordinator, house)
	if not NpcSimulationServer.is_seeded:
		await NpcSimulationServer.seed_finished
	sunny = EsmServer.find_reference_by_editor_id("SunnyRef") as ActorReference
	var sunny_space := sunny.current_space_form_id
	_log("start")
	ScriptServer.run_debug_line("player.moveto SunnyRef")
	await _await_space(coordinator, sunny_space)
	_log("player with Sunny")
	print(ScriptServer.run_debug_line("set VFreeformGoodsprings.bMetSunny to 1"))
	print(ScriptServer.run_debug_line("StartQuest VCG02"))
	print(ScriptServer.run_debug_line("SetStage VCG02 10"))
	var wasteland := int(EsmServer.reader.find_worldspace_by_editor_id("WastelandNV").get("form_id", 0))
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while sunny.current_space_form_id != wasteland and Time.get_ticks_msec() < deadline:
		await _wait_seconds(1.0)
		_log("walking out")
	_log("Sunny outside")
	await _wait_seconds(3.0)
	_log("3 s later")
	ScriptServer.run_debug_line("player.moveto SunnyRef")
	await _await_space(coordinator, wasteland)
	for second in 8:
		await _wait_seconds(1.0)
		_log("player outside, after player.moveto SunnyRef")
	ScriptServer.run_debug_line("SunnyRef.moveto player")
	for second in 4:
		await _wait_seconds(1.0)
		_log("after SunnyRef.moveto player")
	get_tree().quit()

func _log(label: String) -> void:
	var node := EsmNode.node_for(sunny)
	var node_text := "none"
	if node != null:
		node_text = "%s (in tree %s, visible %s, process %s)" % [node.get_path() if node.is_inside_tree() else NodePath(node.name), node.is_inside_tree(), node.is_visible_in_tree() if node.is_inside_tree() else false, node.can_process() if node.is_inside_tree() else false]
	var world: WorldStreamerV2 = game.world_streamer
	var tile := world._tile_root_for(sunny) if world.is_active() else null
	var player_ref := EsmServer.get_player_reference()
	var state := "Sunny space %08X cell %08X at %s mode %d disabled %s package %s target %s | node %s | world active %s paused %s, her tile %s | player space %08X at %s, coordinator %08X" % [
		sunny.current_space_form_id, sunny.current_cell_form_id, sunny.position.snapped(Vector3.ONE * 0.1), sunny.simulation_mode, sunny.is_disabled(),
		sunny.active_package.editor_id if sunny.active_package != null else "none",
		sunny.move_target, node_text, world.is_active(), world.is_paused(), tile.name if tile != null else "none",
		player_ref.current_space_form_id, player_ref.position.snapped(Vector3.ONE * 0.1), game.transition_coordinator.loaded_space_form_id]
	if state == _last_state:
		return
	_last_state = state
	print("[%s %.1f s] %s" % [label, Time.get_ticks_msec() / 1000.0, state])

func _await_space(coordinator: TransitionCoordinator, space_form_id: int) -> void:
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while (coordinator.loaded_space_form_id != space_form_id or coordinator.is_transitioning()) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

func _wait_seconds(seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
