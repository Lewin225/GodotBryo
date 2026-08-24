extends Node3D

# 2.0 — Resource Caching + Instancing. See
# phases/2/00-resource-caching-instancing.md. Loads the same two cells
# (Goodsprings exterior + GSDocMitchellHouse interior) twice through one
# shared GamebryoMeshResolver: pass 1 is cold (every mesh/texture/collision
# shape genuinely new), pass 2 is entirely repeat placements of objects
# already resolved in pass 1. If caching works, pass 2 should be
# near-100%-cache-hit and meaningfully faster wall-clock than pass 1 — a
# real measured before/after within one run, not an assumption.

const DATA_DIR := "../fresh_nv_copy/Data/"
const WORLDSPACE_EDITOR_ID := "WastelandNV"
const CELL_GRID_X := -17
const CELL_GRID_Y := 0

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

# Loads the interior cell's + exterior cell's REFRs (objects only — not
# terrain, which has its own single-cell cost unrelated to per-object
# caching) into a throwaway root, returns object count placed.
func load_pass(esm: EsmReader, registry: GamebryoObjectRegistry, root: Node3D) -> int:
	var placed := 0

	var interior: Dictionary = esm.find_cell_by_editor_id("GSDocMitchellHouse")
	for p in esm.get_cell_references(int(interior["form_id"])):
		var node := registry.build(p)
		if node != null:
			root.add_child(node)
			placed += 1

	var wrld: Dictionary = esm.find_worldspace_by_editor_id(WORLDSPACE_EDITOR_ID)
	var ext_cell: Dictionary = esm.find_exterior_cell(int(wrld["form_id"]), CELL_GRID_X, CELL_GRID_Y)
	for p in esm.get_cell_references(int(ext_cell["form_id"])):
		var node := registry.build(p)
		if node != null:
			root.add_child(node)
			placed += 1

	return placed

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")

	var resolver := GamebryoMeshResolver.new()
	var registry := GamebryoObjectRegistry.new(resolver, esm)

	var root1 := Node3D.new()
	add_child(root1)
	var t0 := Time.get_ticks_usec()
	var placed1 := load_pass(esm, registry, root1)
	var t1 := Time.get_ticks_usec()
	var pass1_ms := (t1 - t0) / 1000.0
	var stats1 := resolver.get_cache_stats()
	print("pass 1 (cold): placed=", placed1, " time=", pass1_ms, "ms stats=", stats1)

	root1.queue_free()
	resolver.reset_cache_stats()

	var root2 := Node3D.new()
	add_child(root2)
	var t2 := Time.get_ticks_usec()
	var placed2 := load_pass(esm, registry, root2)
	var t3 := Time.get_ticks_usec()
	var pass2_ms := (t3 - t2) / 1000.0
	var stats2 := resolver.get_cache_stats()
	print("pass 2 (warm, same objects): placed=", placed2, " time=", pass2_ms, "ms stats=", stats2)

	check(placed1 == placed2, "both passes placed the same number of objects (%d vs %d)" % [placed1, placed2])
	check(int(stats2["mesh_cache_misses"]) == 0, "pass 2 had zero mesh cache misses (got %d)" % stats2["mesh_cache_misses"])
	check(int(stats2["material_cache_misses"]) == 0, "pass 2 had zero material cache misses (got %d)" % stats2["material_cache_misses"])
	check(int(stats2["mesh_cache_hits"]) > 0, "pass 2 had real cache hits (%d)" % stats2["mesh_cache_hits"])
	check(pass2_ms < pass1_ms * 0.5, "pass 2 was meaningfully faster than pass 1 (%.1fms vs %.1fms)" % [pass2_ms, pass1_ms])

	# Same-cell repeats within pass 1 itself already exercise caching (many
	# REFRs share a base object even on a first-ever load) — report the
	# ratio directly rather than just asserting pass 2 improved.
	var mesh_total: int = int(stats1["mesh_cache_hits"]) + int(stats1["mesh_cache_misses"])
	if mesh_total > 0:
		print("pass 1 in-cell mesh cache hit rate: %.1f%% (%d/%d)" %
				[100.0 * stats1["mesh_cache_hits"] / mesh_total, stats1["mesh_cache_hits"], mesh_total])
	check(int(stats1["mesh_cache_hits"]) > 0, "even the cold pass had in-cell repeat hits (%d)" % stats1["mesh_cache_hits"])

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
