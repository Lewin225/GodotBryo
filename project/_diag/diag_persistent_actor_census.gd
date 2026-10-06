extends Node

## Census: for each worldspace with a persistent CELL, how many ACHR/ACRE are
## filed in it, and how many of those the streamer's persistent list returns.
func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var total_actors := 0
	var total_listed := 0
	for worldspace_form_id: int in EsmServer._persistent_cell_by_worldspace.keys():
		var persistent_cell := int(EsmServer._persistent_cell_by_worldspace[worldspace_form_id])
		var actors: Array = EsmServer.reader.get_cell_actors(persistent_cell)
		if actors.is_empty():
			continue
		var listed := EsmServer.get_persistent_references_for_worldspace(worldspace_form_id)
		var listed_actors := 0
		for reference in listed:
			if reference is ActorReference:
				listed_actors += 1
		total_actors += actors.size()
		total_listed += listed_actors
		print("WRLD %08X: %d persistent actors filed, %d in the persistent list" % [worldspace_form_id, actors.size(), listed_actors])
	print("total: %d persistent actors filed, %d in the persistent list" % [total_actors, total_listed])
	get_tree().quit()
