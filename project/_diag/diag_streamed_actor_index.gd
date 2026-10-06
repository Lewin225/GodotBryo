extends Node

## For each named actor reference: its filing cell, current cell and space,
## whether EsmServer counts it relocated, and whether it appears in the lists
## WorldStreamerV2 populates from (the worldspace's persistent references and
## its grid CELL's references), before and after NpcSimulationServer seeds and
## a few seconds of simulation.
func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	_report("before seed")
	NpcSimulationServer.seed()
	await NpcSimulationServer.seed_finished
	_report("after seed")
	for frame in 300:
		await get_tree().process_frame
	_report("after 300 frames")
	get_tree().quit()

func _report(label: String) -> void:
	print("== ", label)
	for editor_id in OS.get_cmdline_user_args():
		var reference := EsmServer.find_reference_by_editor_id(editor_id)
		if reference == null:
			print("%s: not found" % editor_id)
			continue
		var space := reference.current_space_form_id
		var grid := Vector2i(floori(reference.position.x / 57.142857), floori(reference.position.y / 57.142857))
		var grid_cell := EsmServer.get_exterior_cell_form_id(space, grid)
		var in_persistent := EsmServer.get_persistent_references_for_worldspace(space).has(reference)
		var in_grid := EsmServer.get_references_in_cell(grid_cell).has(reference)
		print("%s: filing cell %08X, current cell %08X, space %08X, grid %s cell %08X, relocated %s, in persistent list %s, in grid cell list %s, disabled %s" % [editor_id, EsmServer.get_filing_cell_form_id(reference.instance_id.trim_prefix("authored:").hex_to_int()), reference.current_cell_form_id, space, grid, grid_cell, EsmServer.is_relocated(reference), in_persistent, in_grid, reference.is_disabled()])
