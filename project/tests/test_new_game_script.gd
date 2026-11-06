extends Node

var failures := 0

func check(ok: bool, message: String) -> void:
	print("  OK   " if ok else "  FAIL ", message)
	if not ok:
		failures += 1

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var game := (load("res://game.tscn") as PackedScene).instantiate()
	add_child(game)
	var coordinator: TransitionCoordinator = game.transition_coordinator
	var house := int(EsmServer.reader.find_cell_by_editor_id("GSDocMitchellHouse").get("form_id", 0))
	var deadline := Time.get_ticks_msec() + 30000
	while (coordinator.loaded_space_form_id != house or coordinator.is_transitioning()) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	check(coordinator.loaded_space_form_id == house, "Loaded GSDocMitchellHouse via default startup script")
	var vcg01 := EsmServer.find_quest_by_editor_id("VCG01") as QuestBase
	check(QuestServer.is_running(vcg01) and QuestServer.is_stage_done(vcg01, 0), "VCG01 running with stage 0 done")
	check(QuestServer.active_quest == vcg01, "VCG01 is active quest")
	var marker: EsmReference = EsmServer.find_reference_by_editor_id("VCG01PlayerStartMarkerREF")
	check(marker != null, "Found start marker")
	if marker != null:
		check(EsmReferencePhysicaliser.authored_position(game.player.global_position).distance_to(marker.position) < 0.5, "Player at start marker")
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
