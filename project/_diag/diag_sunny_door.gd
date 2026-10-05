extends Node

## Sunny Smiles' way out of her cell: the load doors NpcSimulationServer's
## door sequence picks from her to WastelandNV, each door's lock, base and
## script, and the script's source.

func _ready() -> void:
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	NpcSimulationServer.records_per_frame = 512
	NpcSimulationServer.seed()
	if not NpcSimulationServer.is_seeded:
		await NpcSimulationServer.seed_finished
	var sunny := EsmServer.find_reference_by_editor_id("SunnyRef") as ActorReference
	if sunny == null:
		print("SunnyRef not found")
		get_tree().quit()
		return
	print("Sunny: space %08X, cell %08X, at %s" % [sunny.current_space_form_id, sunny.current_cell_form_id, sunny.position])
	print("cell editor id: %s" % EsmServer.reader.get_cell_editor_id(sunny.current_space_form_id) if EsmServer.reader.has_method("get_cell_editor_id") else "")
	for portal in NpcSimulationServer.portals_by_source_space.get(sunny.current_space_form_id, []):
		var door: DoorReference = portal.source_reference
		var raw: Dictionary = EsmServer.reader.get_record_data(int(door.instance_id.trim_prefix("authored:").hex_to_int()))
		var xloc := "none"
		for sub in raw.get("subrecords", []):
			if sub["type"] == "XLOC":
				xloc = (sub["data"] as PackedByteArray).hex_encode()
		print("  load door %s base %08X: is_locked %s, lock_level %d, key %08X, XLOC %s, to space %08X" % [door.instance_id, door.base_form_id, door.is_locked, door.lock_level, door.lock_key_form_id, xloc, portal.destination_space_form_id])
	var wasteland := EsmServer.find_form_id_by_editor_id("WastelandNV")
	var goodsprings := EsmServer.find_reference_by_editor_id("DocMitchellREF")
	var front_door := EsmServer.get_reference("authored:00103E61") as DoorReference
	var sequence: Dictionary = NpcSimulationServer.find_door_sequence(sunny.current_space_form_id, sunny.position, wasteland, front_door.teleport_position, NpcSimulationServer.blocked_doors_for(sunny))
	print("door sequence found %s, %d doors" % [sequence["found"], sequence["portals"].size()])
	for portal in sequence["portals"]:
		var door: DoorReference = portal.source_reference
		var base := door.base
		print("  door %s base %08X %s: locked %s, open by default %s, script %s, to space %08X" % [door.instance_id, door.base_form_id, base.editor_id if base != null else "?", door.is_locked, door.is_open_by_default, base.script_record.editor_id if base != null and base.script_record != null else "none", portal.destination_space_form_id])
		var route: Dictionary = NpcSimulationServer.route(sunny.current_space_form_id, sunny.position, portal.source_position)
		print("    route from Sunny to the door: found %s" % route.get("found", false))
		if base != null and base.script_record != null:
			var data: Dictionary = EsmServer.reader.get_script_data(base.script_record.form_id)
			print(String(data.get("source", "(no source)")))
	get_tree().quit()
