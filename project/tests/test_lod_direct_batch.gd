extends Node3D

# 2.12 step 7 -- the RID-based construct path: DirectGeometryBatch's second
# MeshGroup tier for LOD meshes, with instance_geometry_set_visibility_range()
# set on both tiers. RenderingServer has no getter for an instance's own
# visibility_range, so the parts of this test that still go through the RID
# path verify through DirectGeometryBatch's own instance-count bookkeeping
# (get_lod_instance_count()) rather than reading the range back directly.
#
# Issue #56: VWD-flagged placements with a real lod_geometry companion are
# NO LONGER routed through DirectGeometryBatch at all -- construct_from_
# resolved() sends them to the Node-based path instead (see that function's
# own doc comment for why: DirectGeometryBatch's per-tile MultiMesh batching
# gives every placement of a shared mesh ONE shared visibility_range,
# measured from the camera to the combined instance AABB's center, which
# breaks near-fade for spread-out repeated meshes like the Strip perimeter
# wall). DirectGeometryBatch's own LOD-tier machinery (tested directly
# below via add_object()) is otherwise untouched -- this only changed which
# placements construct_from_resolved() feeds into it.
# See phases/2/12-distant-object-lod.md.

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

	print("=== both resolve as structural-fallback (kind=visual, type_tag empty), the primary DirectGeometryBatch path ===")
	var barracks_result: Dictionary = {}
	var quonset_result: Dictionary = {}
	if not barracks_placement.is_empty():
		barracks_result = registry.resolve_placement(barracks_placement, ctx, true)
		check(barracks_result.get("kind", "") == "visual" and barracks_result.get("type_tag", "x") == "",
				"Barracks01 resolves as structural fallback (kind=%s, type_tag=%s)" % [barracks_result.get("kind", ""), barracks_result.get("type_tag", "")])
		check(barracks_result.has("lod_geometry"), "Barracks01's resolved result carries lod_geometry")
	if not quonset_placement.is_empty():
		quonset_result = registry.resolve_placement(quonset_placement, ctx, true)
		check(quonset_result.get("kind", "") == "visual" and quonset_result.get("type_tag", "x") == "",
				"QuonsetHut01 resolves as structural fallback (kind=%s, type_tag=%s)" % [quonset_result.get("kind", ""), quonset_result.get("type_tag", "")])
		check(not quonset_result.has("lod_geometry"), "QuonsetHut01's resolved result does NOT carry lod_geometry")

	print("=== issue #56: a VWD-eligible placement is routed to a real Node even when a batch IS provided, and contributes NOTHING to that batch ===")
	if not barracks_result.is_empty():
		var batch := DirectGeometryBatch.new()
		batch.init(self)
		batch.set_lod_crossover(100.0, 5.0)
		var node := registry.construct_from_resolved(barracks_result, batch)
		check(node != null, "construct_from_resolved() with a real batch still returns a real Node for a VWD-eligible placement (issue #56 fix)")
		if node != null:
			node.free()
		batch.build()
		check(batch.get_instance_count() == 0, "the batch got NO instances at all from a VWD-eligible placement (got %d)" % batch.get_instance_count())
		batch.free_all()

	print("=== a non-VWD batch (same _lod.nif-companion-having model, but not VWD-flagged) gets NO LOD instance tier ===")
	if not quonset_result.is_empty():
		var batch := DirectGeometryBatch.new()
		batch.init(self)
		batch.set_lod_crossover(100.0, 5.0)
		registry.construct_from_resolved(quonset_result, batch)
		batch.build()
		check(batch.get_lod_instance_count() == 0, "QuonsetHut01-only batch has NO LOD instance tier (got %d)" % batch.get_lod_instance_count())
		check(batch.get_instance_count() > 0, "the batch still has its own full-detail instances (got %d)" % batch.get_instance_count())
		batch.free_all()

	print("=== get_batched_placement_count() counts only full-detail entries, unaffected by the LOD tier ===")
	if not barracks_result.is_empty():
		var geometry := resolver.build_geometry_entries(barracks_result.get("geometry", {}), barracks_result.get("lod_geometry", {}))
		var full_count: int = geometry["mesh_entries"].size()
		var lod_count: int = geometry.get("lod_mesh_entries", []).size()
		check(lod_count > 0, "Barracks01 has real lod_mesh_entries to compare against (got %d)" % lod_count)
		var batch := DirectGeometryBatch.new()
		batch.init(self)
		var pos: Vector3 = barracks_placement.get("position", Vector3.ZERO)
		var rot: Vector3 = barracks_placement.get("rotation", Vector3.ZERO)
		var scale: float = barracks_placement.get("scale", 1.0)
		var world_transform := GamebryoMeshResolver.world_transform_no_parent(pos, rot, scale)
		batch.add_object(world_transform, geometry["mesh_entries"], geometry["shape_entries"], geometry["lod_mesh_entries"])
		check(batch.get_batched_placement_count() == full_count,
				"get_batched_placement_count() (%d) matches full-detail mesh_entries.size() (%d), not full+lod (%d)" % [batch.get_batched_placement_count(), full_count, full_count + lod_count])
		batch.free_all()

	print("=== mixed call: a VWD-eligible placement (Node) and a non-VWD placement (batch) coexist correctly, each on its own path ===")
	if not barracks_result.is_empty() and not quonset_result.is_empty():
		var batch := DirectGeometryBatch.new()
		batch.init(self)
		batch.set_lod_crossover(100.0, 5.0)
		var barracks_node := registry.construct_from_resolved(barracks_result, batch)
		registry.construct_from_resolved(quonset_result, batch)
		check(barracks_node != null, "Barracks01 still gets a real Node even alongside a batch-routed QuonsetHut01")
		if barracks_node != null:
			barracks_node.free()
		batch.build()
		check(batch.get_lod_instance_count() == 0, "the batch has NO LOD tier at all -- Barracks01 never reached it (got %d)" % batch.get_lod_instance_count())
		check(batch.get_instance_count() > 0, "the batch still has QuonsetHut01's own full-detail instances (got %d)" % batch.get_instance_count())
		batch.free_all()

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
