extends SceneTree

## Softlock investigation: how many real exterior cells does Freeside's own
## worldspace actually have, and how are they distributed in grid space --
## checking whether a door landing near Freeside's edge/center plausibly
## puts most of RADIUS_LOAD_DISTANT's (20-tile) circle over grid coords
## with NO real cell (esm.find_exterior_cell() returns {}), which is the
## trigger condition for the suspected _process_load_queue() settled-signal
## gap.

func _init() -> void:
	var esm := EsmReader.new()
	if not esm.open(GamebryoMeshResolver.get_data_dir() + "FalloutNV.esm"):
		push_error("could not open FalloutNV.esm")
		quit(1)
		return

	for name in ["FreesideWorld", "FreesideNorthWorld", "FreesideFortWorld", "WastelandNV"]:
		var wrld: Dictionary = esm.find_worldspace_by_editor_id(name)
		if wrld.is_empty():
			print(name, " -> worldspace not found")
			continue
		var wrld_id := int(wrld["form_id"])
		print(name, " -> form_id=0x%X" % wrld_id)
		# Sweep a generous grid range and count real cells + their bounding
		# range, since we don't have a direct "list all cells" API here.
		var found := 0
		var minx := 999999
		var maxx := -999999
		var miny := 999999
		var maxy := -999999
		for gx in range(-30, 31):
			for gy in range(-30, 31):
				var cell: Dictionary = esm.find_exterior_cell(wrld_id, gx, gy)
				if not cell.is_empty():
					found += 1
					minx = mini(minx, gx)
					maxx = maxi(maxx, gx)
					miny = mini(miny, gy)
					maxy = maxi(maxy, gy)
		print("  cells found in [-30,30]^2 sweep: ", found)
		if found > 0:
			print("  grid range: x[", minx, ",", maxx, "] y[", miny, ",", maxy, "]")
	quit()
