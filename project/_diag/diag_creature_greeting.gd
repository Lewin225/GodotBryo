extends Node

## Prints the GREETING INFO a few talking creatures give the player.

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	QuestServer.begin_game()
	var greeting := EsmServer.find_base_by_editor_id("GREETING") as DialogueTopicBase
	for editor_id in ["DocMitchellREF", "VictorREF", "GSVictorREF"]:
		var ref := EsmServer.find_reference_by_editor_id(editor_id)
		var chosen := DialogueServer.choose_info(greeting, ref, ScriptServer.player_reference) if ref != null else null
		print("%s %s -> %s" % [editor_id, ref.base.editor_id if ref != null else "missing", chosen.editor_id if chosen != null else "none"])
	var talkers := 0
	var creatures := 0
	for actor: ActorReference in EsmServer.get_all_placed_actor_references():
		if not (actor.base is CreatureBase):
			continue
		creatures += 1
		var info := DialogueServer.choose_info(greeting, actor, ScriptServer.player_reference)
		if info == null:
			continue
		talkers += 1
		if talkers <= 12:
			print("%s %s -> %s" % [actor.instance_id, actor.base.editor_id, info.editor_id])
	print("placed creatures %d, with a GREETING for the player %d" % [creatures, talkers])
	get_tree().quit()
