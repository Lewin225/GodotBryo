extends Node

## Prints the leveled choice of every placed actor in the Vault3Zone cells, at
## player level 1.

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var counts := {}
	for actor: ActorReference in EsmServer.get_all_placed_actor_references():
		var zone := actor.get_encounter_zone()
		if zone == null or zone.editor_id != "Vault3Zone":
			continue
		if ActorBase.leveled_list_in_chain(actor.base) == null:
			continue
		var choice := actor.get_leveled_template()
		var cell: String = EsmServer.reader.get_cell_editor_id(actor.current_cell_form_id)
		print("%s %s %s XLCM %s -> %s at %d" % [cell, actor.instance_id, actor.base.editor_id, ActorDebugLabel._modifier_name(actor.level_modifier), choice.editor_id if choice else "none", actor.leveled_template_level])
		var key := "%s -> %s" % [ActorBase.leveled_list_in_chain(actor.base).editor_id, choice.editor_id if choice else "none"]
		counts[key] = int(counts.get(key, 0)) + 1
	print("---")
	for key in counts:
		print("%3d  %s" % [counts[key], key])
	get_tree().quit()
