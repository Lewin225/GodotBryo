extends Node

## Save sections: a new game runs (quests begun, actors seeded and simulated,
## VCG01 started, the player renamed, a door opened, a container filled, a
## runtime weapon made, a topic added), then EsmServer, QuestServer,
## ScriptServer and DialogueServer save. The save goes through JSON text and
## loads into new QuestServer, ScriptServer and DialogueServer instances and a
## cleared EsmServer, whose saved references are then built; saving again
## gives the same text. Prints the save's size and the save and load times.
##
## SAVE_SECTIONS_SECONDS (default 10) sets how long the simulation runs at
## LowLevelTravel speed 50 before saving, for measuring a long session;
## SAVE_SECTIONS_DUMP, a path, writes the save's text there.

const QuestServerScript := preload("res://GodotBryo/Servers/QuestServer/quest_server.gd")
const ScriptServerScript := preload("res://GodotBryo/Servers/ScriptServer/script_server.gd")
const DialogueServerScript := preload("res://GodotBryo/Servers/DialogueServer/dialogue_server.gd")

var failures := 0

func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	QuestServer.begin_game()
	NpcSimulationServer.seed()
	await NpcSimulationServer.seed_finished
	var vcg01 := EsmServer.find_quest_by_editor_id("VCG01")
	QuestServer.set_stage(vcg01, 0)
	QuestServer.active_quest = vcg01
	var player := EsmServer.get_player_reference()
	player.base.full_name = "Courier Six"
	player.base.mark_changed("full_name")
	var door := EsmServer.get_reference_by_form_id(0x0010901D) as DoorReference
	door.is_open = not door.is_open
	var stimpak := EsmServer.find_base_by_editor_id("Stimpak")
	var container := _first_container()
	container.contents.add_item(stimpak.form_id, null, 4)
	var weapon := EsmServer.create_runtime_reference(0x000E3778) as WeaponReference
	weapon.condition = 0.3
	DialogueServer.add_topic(EsmServer.find_base_by_editor_id("GREETING") as DialogueTopicBase)

	var seconds := float(OS.get_environment("SAVE_SECTIONS_SECONDS")) if not OS.get_environment("SAVE_SECTIONS_SECONDS").is_empty() else 10.0
	NpcSimulationServer.low_level_travel.speed_scale = 50.0
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		await get_tree().process_frame
	NpcSimulationServer.low_level_travel.speed_scale = 1.0

	# Save, then load and save again within one frame, so nothing moves between.
	var save_started := Time.get_ticks_usec()
	var saved := _save_all(EsmServer, QuestServer, ScriptServer, DialogueServer)
	var save_usec := Time.get_ticks_usec() - save_started
	check(not SaveFields.holds_object(saved), "the save holds no Object")
	var text := JSON.stringify(saved, "\t", true)
	var references: Dictionary = saved["esm_server"]["references"]
	check(references.has("player") and references.has(String(door.instance_id)) and references.has(String(container.instance_id)),
			"the player, the opened door and the filled container are saved")
	check((saved["esm_server"]["runtime"]["references"] as Dictionary).has(String(weapon.instance_id)), "the runtime weapon is saved")
	check((saved["esm_server"]["bases"] as Dictionary).has(String(EsmServer.instance_id_for_form_id(player.base_form_id))), "the renamed player NPC_ is saved by its changed field")
	check((references[String(container.instance_id)] as Dictionary).has("contents"), "the filled container's inventory is saved")
	var moved_actors := 0
	var with_contents := 0
	for id: String in references:
		if id != "player":
			moved_actors += 1
		if (references[id] as Dictionary).has("contents"):
			with_contents += 1
	check(with_contents < moved_actors / 10, "inventories unchanged since they were built are left out (%d of %d saved)" % [with_contents, moved_actors])
	print("  saved %d references, %d quest states, %d globals" % [moved_actors, (saved["quest_server"]["states"] as Dictionary).size(), (saved["script_server"]["globals"] as Dictionary).size()])

	var load_started := Time.get_ticks_usec()
	var parsed: Dictionary = JSON.parse_string(text)
	var quests := QuestServerScript.new()
	var scripts := ScriptServerScript.new()
	var dialogue := DialogueServerScript.new()
	EsmServer.clear_game_state()
	EsmServer.load_state(parsed["esm_server"])
	quests.load_state(parsed["quest_server"])
	scripts.load_state(parsed["script_server"])
	dialogue.load_state(parsed["dialogue_server"])
	EsmServer.get_player_reference()
	for id: String in references:
		EsmServer.get_reference(StringName(id))
	var load_usec := Time.get_ticks_usec() - load_started
	check(EsmServer._saved_references.is_empty(), "every saved reference was built and took its entry")
	check(EsmServer.get_player_reference().base.full_name == "Courier Six", "the player NPC_ loads with its saved name")
	var resaved_text := JSON.stringify(_save_all(EsmServer, quests, scripts, dialogue), "\t", true)
	var difference := SaveCompare.first_difference(JSON.parse_string(text), JSON.parse_string(resaved_text))
	check(difference.is_empty(), "saving after the load gives the same save (floats within 1e-9)")
	if not difference.is_empty():
		print("  first difference: ", difference)

	var dump_path := OS.get_environment("SAVE_SECTIONS_DUMP")
	if not dump_path.is_empty():
		var file := FileAccess.open(dump_path, FileAccess.WRITE)
		file.store_string(text)
		file.close()
	var bytes := text.to_utf8_buffer()
	print("  save %d bytes (%d zstd), save_state %.1f ms, parse and load %.1f ms"
			% [bytes.size(), bytes.compress(FileAccess.COMPRESSION_ZSTD).size(), save_usec / 1000.0, load_usec / 1000.0])
	for node: Node in [quests, scripts, dialogue]:
		node.free()
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(1 if failures > 0 else 0)

func _save_all(esm_server, quests, scripts, dialogue) -> Dictionary:
	return {
		"esm_server": esm_server.save_state(),
		"quest_server": quests.save_state(),
		"script_server": scripts.save_state(),
		"dialogue_server": dialogue.save_state(),
	}

func _first_container() -> ContainerReference:
	for row: Dictionary in EsmServer.get_record_index():
		if String(row.get("record_type", "")) != "REFR":
			continue
		var reference := EsmServer.get_reference_by_form_id(int(row.get("form_id", 0)))
		if reference is ContainerReference:
			return reference
	return null
