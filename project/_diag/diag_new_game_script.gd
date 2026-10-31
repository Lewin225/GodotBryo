extends Node

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
	assert(coordinator.loaded_space_form_id == house, "Loaded GSDocMitchellHouse via default startup script")
	var vcg01 := EsmServer.find_quest_by_editor_id("VCG01") as QuestBase
	assert(QuestServer.is_running(vcg01) and QuestServer.get_stage(vcg01) == 0, "VCG01 running at stage 0")
	assert(QuestServer.active_quest == vcg01, "VCG01 is active quest")
	var marker: EsmReference = EsmServer.find_reference_by_editor_id("VCG01PlayerStartMarkerREF")
	assert(marker != null, "Found start marker")
	assert(EsmReferencePhysicaliser.authored_position(game.player.global_position).distance_to(marker.position) < 0.5, "Player at start marker")
	print("ALL CHECKS PASSED")
	get_tree().quit(0)

