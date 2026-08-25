extends SceneTree

const GameDataConfigScript := preload("res://game_data_config.gd")

## Follow-up: no "Freeside"/"FreesideNV" worldspace editor ID exists.
## Find any cell whose editor ID contains "freeside" directly (via
## find_cell_by_editor_id on plausible names), and check whether it's
## interior or exterior via get_cell_worldspace().

func _init() -> void:
	var esm := EsmReader.new()
	if not esm.open(String(GameDataConfigScript.resolve().get("data_dir", "")) + GameDataConfigScript.ESM_FILE):
		push_error("could not open FalloutNV.esm")
		quit(1)
		return

	var candidates := [
		"FreesideEast", "FreesideWest", "FreesideOuterVegas", "FreesideOldMormonFort",
		"FreesideNorth", "FreesideSouth", "Freeside01", "FreesideExt",
		"OuterVegas", "NVFreeside", "FSEast", "FSWest",
	]
	for name in candidates:
		var cell: Dictionary = esm.find_cell_by_editor_id(name)
		if not cell.is_empty():
			var cell_id := int(cell["form_id"])
			var wrld_id: int = esm.get_cell_worldspace(cell_id)
			print(name, " -> form_id=0x%X wrld=%s" % [cell_id, ("interior(-1)" if wrld_id == -1 else "0x%X" % wrld_id)])
		else:
			print(name, " -> not found")
	quit()
