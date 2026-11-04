extends Node

## Quick load into a running game: a new game in Doc Mitchell's house quick
## saves; then a quest stage, a door and the player's position change; F6's
## quick_load() puts all three back, Doc's line being said at the save is
## said again and its end script runs, with the player possessed, placed and
## released. A second quick load builds no NIF
## tree it has not built before (NifServer's tree cache is kept). Saves go to
## user://test_quick_load and are deleted after; with SAVE_BACKEND=git they
## are commits in user://test_quick_load_git (GitBackend), whose refs are
## deleted after.

const ROOT := "user://test_quick_load"
const TIMEOUT_MSEC := 120000
## Doc's "Go ahead and give the vigor tester a try"; its end script displays
## VCG01 objective 30.
const TRY_TESTER_INFO := 0x001074A2

var failures := 0
var game: Node3D

func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var backend: SaveBackend = JsonFolderBackend.new(ROOT)
	if OS.get_environment("SAVE_BACKEND") == "git":
		backend = GitBackend.new(ROOT + "_git")
	SaveServer.register_backend("test", backend)
	SaveServer.backend_name = "test"
	game = (load("res://game.tscn") as PackedScene).instantiate()
	add_child(game)
	var house := int(EsmServer.reader.find_cell_by_editor_id("GSDocMitchellHouse").get("form_id", 0))
	check(await _await_settled(house), "a new game loads Doc Mitchell's house")

	var vms20 := EsmServer.find_quest_by_editor_id("VMS20")
	QuestServer.set_stage(vms20, 5)
	var back_door := EsmServer.get_reference_by_form_id(0x0010901D) as DoorReference
	var door_saved := back_door.is_open
	var player_ref := EsmServer.get_player_reference()
	var saved_position := player_ref.position
	var doc := EsmServer.find_reference_by_editor_id("DocMitchellREF")
	var vcg01 := EsmServer.find_quest_by_editor_id("VCG01")
	var try_tester := EsmServer.get_base(TRY_TESTER_INFO) as DialogueInfoBase
	var try_line := DialogueServer.say(doc, EsmServer.get_base(try_tester.topic_form_id) as DialogueTopicBase, player_ref, try_tester)
	check(try_line != null and not QuestServer.is_objective_displayed(vcg01, 30), "Doc is saying the vigor tester line at the save, objective 30 not yet displayed")
	check(SaveServer.save(game.QUICK_SAVE_ID) == OK, "quick save: %s" % ", ".join(SaveServer.report))

	QuestServer.set_stage(vms20, 50)
	DialogueServer.reset()
	back_door.is_open = not door_saved
	game.player.global_position += Vector3(2.0, 0.0, 0.0)
	for _frame in 3:
		await get_tree().physics_frame
	check(player_ref.position.distance_to(saved_position) > 1.5, "the player has moved away from the saved position")

	await game.quick_load()
	check(await _await_settled(house), "quick load puts the player back in the house")
	var loaded_player := EsmServer.get_player_reference()
	check(loaded_player != player_ref and game.player.possessed == loaded_player, "the controller possesses the loaded player's reference")
	check(loaded_player.position.distance_to(saved_position) < 0.5, "the player is where they were saved (%.3f m off, after the released body settles)" % loaded_player.position.distance_to(saved_position))
	check(EsmReferencePhysicaliser.authored_position(game.player.global_position).distance_to(saved_position) < 0.5, "the body stands there")
	check(not game.player.frozen and not get_tree().paused, "the body is released and the game unpaused")
	check(QuestServer.get_stage(EsmServer.find_quest_by_editor_id("VMS20")) == 5, "VMS20 is back at its saved stage")
	var loaded_door := EsmServer.get_reference_by_form_id(0x0010901D) as DoorReference
	check(loaded_door != back_door and loaded_door.is_open == door_saved, "the back door is back as it was saved")
	var said_again := DialogueServer.get_line(EsmServer.find_reference_by_editor_id("DocMitchellREF"))
	check(said_again != null and said_again.info.form_id == TRY_TESTER_INFO, "Doc says the line again after the load")
	var deadline := Time.get_ticks_msec() + 30000
	while not QuestServer.is_objective_displayed(EsmServer.find_quest_by_editor_id("VCG01"), 30) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	check(QuestServer.is_objective_displayed(EsmServer.find_quest_by_editor_id("VCG01"), 30), "its end script runs when it finishes: VCG01 objective 30 displayed")
	check(NpcSimulationServer.is_seeded and NpcSimulationServer.actors_by_instance_id.has(String(EsmServer.find_reference_by_editor_id("DocMitchellREF").instance_id)),
			"the simulation is seeded again with the loaded actors")

	var built_before := int(NifServer.get_stats().get("build_count", 0))
	var misses_before := int(NifServer.get_stats().get("tree_cache_misses", 0))
	await game.quick_load()
	check(await _await_settled(house), "a second quick load puts the player back in the house")
	var misses_after := int(NifServer.get_stats().get("tree_cache_misses", 0))
	check(misses_after == misses_before, "the second quick load misses NifServer's tree cache no more (%d -> %d, builds %d -> %d)"
			% [misses_before, misses_after, built_before, int(NifServer.get_stats().get("build_count", 0))])

	for entry: Dictionary in backend.list():
		backend.delete(String(entry["save_id"]))
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

## Waits until `space_form_id` is loaded, no transition or load runs, and the
## body is released.
func _await_settled(space_form_id: int) -> bool:
	var coordinator: TransitionCoordinator = game.transition_coordinator
	var deadline := Time.get_ticks_msec() + TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if coordinator.loaded_space_form_id == space_form_id and not coordinator.is_transitioning() and not game._loading and not game.player.frozen:
			break
		await get_tree().process_frame
	for _frame in 3:
		await get_tree().physics_frame
	return coordinator.loaded_space_form_id == space_form_id and not game.player.frozen
