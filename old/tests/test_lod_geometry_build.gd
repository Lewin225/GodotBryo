extends Node3D

# 2.12 step 5 -- GamebryoMeshResolver.build_geometry_entries()'s optional
# lod_raw parameter, building the LOD mesh's actual ArrayMesh/material the
# same way it already does for full-detail. See
# phases/2/12-distant-object-lod.md.

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
	var resolver := GamebryoMeshResolver.new()
	var registry := GamebryoObjectRegistry.new(resolver, esm)
	var ctx := GamebryoResolveContext.new()

	var wrld: Dictionary = esm.find_worldspace_by_editor_id("WastelandNV")
	check(not wrld.is_empty(), "found WastelandNV")
	var wrld_id := int(wrld["form_id"])

	var barracks_placement: Dictionary = {}
	var quonset_placement: Dictionary = {}
	for gx in range(-40, 40):
		for gy in range(-40, 40):
			if not barracks_placement.is_empty() and not quonset_placement.is_empty():
				break
			var cell: Dictionary = esm.find_exterior_cell(wrld_id, gx, gy)
			if cell.is_empty():
				continue
			var refs: Array = esm.get_cell_references(int(cell["form_id"]))
			for p in refs:
				var model: String = String(p.get("model", "")).to_lower()
				if "barracks01" in model and barracks_placement.is_empty():
					barracks_placement = p
				elif "nvnellisquonsethut01" in model and quonset_placement.is_empty():
					quonset_placement = p
	check(not barracks_placement.is_empty(), "found a real Barracks01 placement")
	check(not quonset_placement.is_empty(), "found a real QuonsetHut01 placement")

	print("=== a VWD placement's lod_geometry builds real ArrayMesh entries via lod_raw ===")
	if not barracks_placement.is_empty():
		var resolved: Dictionary = registry.resolve_placement(barracks_placement, ctx, true)
		check(resolved.has("lod_geometry"), "Barracks01 resolved with a raw lod_geometry block")
		var built: Dictionary = resolver.build_geometry_entries(resolved.get("geometry", {}), resolved.get("lod_geometry", {}))
		check(built.has("lod_mesh_entries"), "build_geometry_entries() result carries lod_mesh_entries")
		var lod_entries: Array = built.get("lod_mesh_entries", [])
		check(not lod_entries.is_empty(), "lod_mesh_entries is non-empty for Barracks01")
		for entry in lod_entries:
			check(entry.get("mesh") is ArrayMesh, "each lod_mesh_entries entry has a real ArrayMesh")
			check(entry.get("mesh").get_surface_count() > 0, "the built LOD ArrayMesh has real surface data")
			check(entry.get("transform") is Transform3D, "each lod_mesh_entries entry has a Transform3D")
		# Full-detail mesh_entries/shape_entries are unaffected by lod_raw being passed.
		check(not built.get("mesh_entries", []).is_empty(), "full-detail mesh_entries still built alongside the LOD tier")

		print("=== the LOD mesh is cached the same way the full-detail mesh is (repeat build reuses it) ===")
		resolver.reset_cache_stats()
		var built_again: Dictionary = resolver.build_geometry_entries(resolved.get("geometry", {}), resolved.get("lod_geometry", {}))
		var stats := resolver.get_cache_stats()
		check(stats["mesh_cache_misses"] == 0, "a second build of the same (raw, lod_raw) pair has zero mesh cache misses (got %d)" % stats["mesh_cache_misses"])
		check(stats["mesh_cache_hits"] > 0, "a second build of the same (raw, lod_raw) pair hits the mesh cache (got %d hits)" % stats["mesh_cache_hits"])
		if not built_again.get("lod_mesh_entries", []).is_empty() and not lod_entries.is_empty():
			check(built_again["lod_mesh_entries"][0]["mesh"] == lod_entries[0]["mesh"],
					"the reused LOD mesh is the exact same ArrayMesh instance, not rebuilt")

	print("=== a non-VWD placement (no lod_geometry) builds an empty lod_mesh_entries, unaffected ===")
	if not quonset_placement.is_empty():
		var resolved: Dictionary = registry.resolve_placement(quonset_placement, ctx, true)
		check(not resolved.has("lod_geometry"), "QuonsetHut01 resolved with no lod_geometry (not VWD-flagged)")
		var built: Dictionary = resolver.build_geometry_entries(resolved.get("geometry", {}))
		check(built.get("lod_mesh_entries", []).is_empty(), "lod_mesh_entries stays empty when no lod_raw is passed at all")
		check(not built.get("mesh_entries", []).is_empty(), "QuonsetHut01 still builds its own full-detail mesh_entries")

	print("=== empty raw returns empty everything, including lod_mesh_entries ===")
	var empty_built: Dictionary = resolver.build_geometry_entries({})
	check(empty_built.get("mesh_entries", ["x"]).is_empty(), "empty raw -> empty mesh_entries")
	check(empty_built.get("shape_entries", ["x"]).is_empty(), "empty raw -> empty shape_entries")
	check(empty_built.get("lod_mesh_entries", ["x"]).is_empty(), "empty raw -> empty lod_mesh_entries")

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
