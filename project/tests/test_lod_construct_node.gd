extends Node3D

# 2.12 step 6 -- the Node-based construct path: a second MeshInstance3D per
# LOD submesh, with visibility_range set on both tiers, built via
# GamebryoMeshResolver.populate_mesh_children(). Verified through BOTH real
# call paths: GamebryoObjectRegistry.build() (CellLoader's own @tool
# editor-preview path, via _instantiate_visual()) and
# resolve_placement()/construct_from_resolved() (the threaded/runtime path,
# with batch=null so it builds a real Node instead of routing through
# DirectGeometryBatch). See phases/2/12-distant-object-lod.md.

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _lod_children(node: Node3D) -> Array:
	var out: Array = []
	for c in node.get_children():
		if c is MeshInstance3D and String(c.name).begins_with("lod"):
			out.append(c)
	return out

func _sub_children(node: Node3D) -> Array:
	var out: Array = []
	for c in node.get_children():
		if c is MeshInstance3D and String(c.name).begins_with("sub"):
			out.append(c)
	return out

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

	print("=== build() (CellLoader's own editor-preview path via _instantiate_visual()) ===")
	if not barracks_placement.is_empty():
		var node := registry.build(barracks_placement)
		check(node != null, "build() produced a node for Barracks01")
		if node != null:
			var subs := _sub_children(node)
			var lods := _lod_children(node)
			check(not subs.is_empty(), "Barracks01 node has full-detail sub* children")
			check(not lods.is_empty(), "Barracks01 node has lod* children (VWD + real _lod.nif companion)")
			for mi in subs:
				check(mi.visibility_range_end == resolver.lod_crossover_distance_m,
						"full-detail %s has visibility_range_end == LOD_CROSSOVER_DISTANCE_M (got %s)" % [mi.name, mi.visibility_range_end])
				check(mi.visibility_range_fade_mode == GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED, "%s uses FADE_DISABLED" % mi.name)
			for mi in lods:
				check(mi.visibility_range_begin == resolver.lod_crossover_distance_m,
						"%s has visibility_range_begin == LOD_CROSSOVER_DISTANCE_M (got %s)" % [mi.name, mi.visibility_range_begin])
			node.free()

	if not quonset_placement.is_empty():
		var node := registry.build(quonset_placement)
		check(node != null, "build() produced a node for QuonsetHut01")
		if node != null:
			var subs := _sub_children(node)
			var lods := _lod_children(node)
			check(not subs.is_empty(), "QuonsetHut01 node has full-detail sub* children")
			check(lods.is_empty(), "QuonsetHut01 node has NO lod* children (not VWD-flagged, despite having a real _lod.nif companion)")
			for mi in subs:
				check(mi.visibility_range_end == 0.0, "%s has NO visibility range set (untouched, ratio unaffected by step 6)" % mi.name)
			node.free()

	print("=== resolve_placement()/construct_from_resolved() (threaded/runtime path, batch=null) ===")
	if not barracks_placement.is_empty():
		var result: Dictionary = registry.resolve_placement(barracks_placement, ctx, true)
		var node := registry.construct_from_resolved(result, null)
		check(node != null, "construct_from_resolved() produced a node for Barracks01")
		if node != null:
			var lods := _lod_children(node)
			check(not lods.is_empty(), "the threaded-path node also has lod* children")
			node.free()

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
