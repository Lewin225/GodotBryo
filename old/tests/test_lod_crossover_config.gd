extends Node3D

# 2.12 step 8 / issue #56 -- the real, single-sourced configurable crossover
# distance/margin, now centralized in the GodotBryoSettings autoload
# instead of duplicated @export vars on WorldStreamer/CellLoader. Verifies:
# GamebryoMeshResolver.set_lod_crossover() actually changes what
# _apply_lod_visibility_range() writes onto real MeshInstance3D children
# (the only place a built value can be read back -- RenderingServer has no
# getter for an RID's own visibility_range, see test_lod_direct_batch.gd's
# own note), and that WorldStreamer/CellLoader actually read
# GodotBryoSettings and thread it into their own `resolver` in _ready().
# See phases/2/12-distant-object-lod.md and issue #56.

const DATA_DIR := "../fresh_nv_copy/Data/"

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")

	print("=== GamebryoMeshResolver defaults to 0.0 (visibly 'unset', not a duplicated tuning literal) before set_lod_crossover() is ever called ===")
	var default_resolver := GamebryoMeshResolver.new()
	check(default_resolver.lod_crossover_distance_m == 0.0, "default lod_crossover_distance_m is 0.0 (got %s)" % default_resolver.lod_crossover_distance_m)
	check(default_resolver.lod_crossover_margin_m == 0.0, "default lod_crossover_margin_m is 0.0 (got %s)" % default_resolver.lod_crossover_margin_m)

	print("=== set_lod_crossover() actually changes what gets written onto real MeshInstance3D children ===")
	var resolver := GamebryoMeshResolver.new()
	resolver.set_lod_crossover(42.0, 3.0)
	check(resolver.lod_crossover_distance_m == 42.0, "resolver.lod_crossover_distance_m reflects the custom value")
	check(resolver.lod_crossover_margin_m == 3.0, "resolver.lod_crossover_margin_m reflects the custom value")

	var registry := GamebryoObjectRegistry.new(resolver, esm)
	var wrld: Dictionary = esm.find_worldspace_by_editor_id("WastelandNV")
	check(not wrld.is_empty(), "found WastelandNV")
	var wrld_id := int(wrld["form_id"])

	var barracks_placement: Dictionary = {}
	for gx in range(-40, 40):
		for gy in range(-40, 40):
			if not barracks_placement.is_empty():
				break
			var cell: Dictionary = esm.find_exterior_cell(wrld_id, gx, gy)
			if cell.is_empty():
				continue
			var refs: Array = esm.get_cell_references(int(cell["form_id"]))
			for p in refs:
				if "barracks01" in String(p.get("model", "")).to_lower() and barracks_placement.is_empty():
					barracks_placement = p
	check(not barracks_placement.is_empty(), "found a real Barracks01 placement")

	if not barracks_placement.is_empty():
		var node := registry.build(barracks_placement)
		check(node != null, "build() produced a node for Barracks01")
		if node != null:
			var saw_full := false
			var saw_lod := false
			for c in node.get_children():
				if c is MeshInstance3D:
					if String(c.name).begins_with("sub"):
						saw_full = true
						check(c.visibility_range_end == 42.0, "%s uses the custom crossover distance, not the old 100.0 default (got %s)" % [c.name, c.visibility_range_end])
						check(c.visibility_range_end_margin == 3.0, "%s uses the custom margin (got %s)" % [c.name, c.visibility_range_end_margin])
					elif String(c.name).begins_with("lod"):
						saw_lod = true
						check(c.visibility_range_begin == 42.0, "%s uses the custom crossover distance (got %s)" % [c.name, c.visibility_range_begin])
						check(c.visibility_range_begin_margin == 3.0, "%s uses the custom margin (got %s)" % [c.name, c.visibility_range_begin_margin])
			check(saw_full, "Barracks01 had full-detail children to check")
			check(saw_lod, "Barracks01 had LOD children to check")
			node.free()

	print("=== GodotBryoSettings (issue #56) reaches WorldStreamer's own resolver in _ready() ===")
	var orig_distance := GodotBryoSettings.lod0_crossover_distance_m
	var orig_margin := GodotBryoSettings.lod0_crossover_margin_m
	GodotBryoSettings.lod0_crossover_distance_m = 77.0
	GodotBryoSettings.lod0_crossover_margin_m = 2.5
	var streamer := WorldStreamer.new()
	add_child(streamer)
	check(streamer.resolver != null, "WorldStreamer built its own resolver in _ready()")
	if streamer.resolver != null:
		check(streamer.resolver.lod_crossover_distance_m == 77.0, "GodotBryoSettings reached resolver.lod_crossover_distance_m (got %s)" % streamer.resolver.lod_crossover_distance_m)
		check(streamer.resolver.lod_crossover_margin_m == 2.5, "GodotBryoSettings reached resolver.lod_crossover_margin_m (got %s)" % streamer.resolver.lod_crossover_margin_m)
	streamer.queue_free()

	print("=== GodotBryoSettings (issue #56) reaches CellLoader's own resolver in _ready() ===")
	GodotBryoSettings.lod0_crossover_distance_m = 33.0
	GodotBryoSettings.lod0_crossover_margin_m = 1.5
	var loader := CellLoader.new()
	add_child(loader)
	check(loader.resolver != null, "CellLoader built its own resolver in _ready()")
	if loader.resolver != null:
		check(loader.resolver.lod_crossover_distance_m == 33.0, "GodotBryoSettings reached resolver.lod_crossover_distance_m (got %s)" % loader.resolver.lod_crossover_distance_m)
		check(loader.resolver.lod_crossover_margin_m == 1.5, "GodotBryoSettings reached resolver.lod_crossover_margin_m (got %s)" % loader.resolver.lod_crossover_margin_m)
	loader.queue_free()
	GodotBryoSettings.lod0_crossover_distance_m = orig_distance
	GodotBryoSettings.lod0_crossover_margin_m = orig_margin

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
