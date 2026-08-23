extends Node3D

# 2.10 step 3 — resolve_placement()/resolve_tile(), including real
# WorkerThreadPool concurrency. See phases/2/10-threaded-streaming-workers.md.

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _first_placement_of_type_by_cell_form_id(esm: EsmReader, cell_form_id: int, type_tag: String) -> Dictionary:
	for placement in esm.get_cell_references(cell_form_id):
		if String(placement.get("base_type", "")) == type_tag:
			return placement
	return {}

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")
	var resolver := GamebryoMeshResolver.new()
	var registry := GamebryoObjectRegistry.new(resolver, esm)

	print("=== resolve_tile() dispatch matches build()'s own known counts (GSDocMitchellHouse) ===")
	var cell: Dictionary = esm.find_cell_by_editor_id("GSDocMitchellHouse")
	check(not cell.is_empty(), "cell found")
	var refs: Array = esm.get_cell_references(int(cell["form_id"]))

	var ctx := GamebryoResolveContext.new()
	var results: Array = registry.resolve_tile(refs, ctx)
	check(results.size() == refs.size(), "one resolve result per input placement (got %d for %d refs)" % [results.size(), refs.size()])

	var by_kind := {}
	var visual_by_type := {}
	for r in results:
		var k: String = r["kind"]
		by_kind[k] = by_kind.get(k, 0) + 1
		if k == "visual":
			var tt: String = r.get("type_tag", "")
			visual_by_type[tt] = visual_by_type.get(tt, 0) + 1

	print("  by kind: ", by_kind)
	print("  visual by type_tag: ", visual_by_type)

	# Cross-checked against test_object_registry.gd's own known-good counts
	# for this exact cell (registry.build()'s counts) -- resolve_tile() must
	# agree with build() on WHICH placements resolve to what, even though it
	# returns data instead of Nodes.
	check(by_kind.get("door", 0) == 2, "both DOOR refs resolved to kind=door (got %d)" % by_kind.get("door", 0))
	check(visual_by_type.get("CONT", 0) == 11, "all 11 CONT refs resolved to kind=visual/CONT (got %d)" % visual_by_type.get("CONT", 0))
	check(visual_by_type.get("ACTI", 0) == 7, "7/11 ACTI refs (mesh-bearing) resolved to kind=visual/ACTI (got %d)" % visual_by_type.get("ACTI", 0))
	check(visual_by_type.get("FURN", 0) == 14, "all 14 FURN refs resolved to kind=visual/FURN (got %d)" % visual_by_type.get("FURN", 0))
	check(by_kind.get("light", 0) == 25, "all 25 LIGH refs resolved to kind=light (got %d)" % by_kind.get("light", 0))
	check(visual_by_type.get("", 0) > 0, "unregistered-but-visual types resolved to kind=visual/'' (structural fallback) (got %d)" % visual_by_type.get("", 0))
	check(by_kind.get("skip", 0) == 6, "6 genuinely unplaceable refs (4 meshless ACTI triggers + 2 meshless SOUN) resolved to kind=skip (got %d)" % by_kind.get("skip", 0))

	for r in results:
		if r["kind"] == "door":
			check(r.has("destination"), "door result carries a destination key (possibly empty for a non-teleporting door)")

	# These are real *exterior* placements, located by a native ESM census:
	# TACT in cell 0x31E2A; TERM and a mesh-bearing MSTT in WastelandNV's
	# persistent cell (0x846EA). Verify WorldStreamer's resolve/commit path
	# keeps their type tag and produces a typed Node instead of batching them.
	print("=== TACT / TERM / MSTT threaded resolve and construct ===")
	var dynamic_fixtures := [
		{ "cell_form_id": 0x846EA, "type": "MSTT", "class": "MovableStaticNode" },
		{ "cell_form_id": 0x31E2A, "type": "TACT", "class": "TalkingActivatorNode" },
		{ "cell_form_id": 0x846EA, "type": "TERM", "class": "TerminalNode" },
	]
	for fixture in dynamic_fixtures:
		var type_tag: String = fixture["type"]
		var cell_form_id: int = fixture["cell_form_id"]
		var placement := _first_placement_of_type_by_cell_form_id(esm, cell_form_id, type_tag)
		check(not placement.is_empty(), "found a real exterior %s placement in cell 0x%X" % [type_tag, cell_form_id])
		if placement.is_empty():
			continue
		var result: Dictionary = registry.resolve_placement(placement, ctx)
		check(result.get("kind", "") == "visual" and result.get("type_tag", "") == type_tag,
				"real %s resolves as kind=visual with its type tag (got kind=%s, type_tag=%s)" % [type_tag, result.get("kind", ""), result.get("type_tag", "")])
		if result.get("kind", "") != "visual":
			continue
		var node := registry.construct_from_resolved(result, DirectGeometryBatch.new())
		check(node != null, "real %s construct result remains a Node even with a batch available" % type_tag)
		if node != null:
			var cls: String = String(node.get_script().get_global_name()) if node.get_script() else node.get_class()
			check(cls == fixture["class"], "real %s threaded construct builds %s (got %s)" % [type_tag, fixture["class"], cls])
			node.free()

	print("=== SCOL recursion (SLGoldMine01INT) ===")
	var scol_cell: Dictionary = esm.find_cell_by_editor_id("SLGoldMine01INT")
	check(not scol_cell.is_empty(), "SCOL test cell found")
	if not scol_cell.is_empty():
		var scol_refs: Array = esm.get_cell_references(int(scol_cell["form_id"]))
		var scol_placements: Array = []
		for p in scol_refs:
			if p["base_type"] == "SCOL":
				scol_placements.append(p)
		check(scol_placements.size() == 3, "found 3 SCOL refs (got %d)" % scol_placements.size())
		for p in scol_placements:
			var r: Dictionary = registry.resolve_placement(p, ctx)
			check(r["kind"] == "scol", "SCOL placement resolves to kind=scol")
			check(r["parts"].size() > 0, "SCOL result has unpacked part results (got %d)" % r["parts"].size())
			for part_result in r["parts"]:
				check(part_result.get("kind", "") in ["visual", "skip"],
						"each SCOL part resolves to a plain placement kind, not a nested SCOL (got %s)" % part_result.get("kind", "?"))

	print("=== real WorkerThreadPool concurrency: results match a synchronous baseline ===")
	# Resolve the same real cell's refs both synchronously (baseline, already
	# computed above as `results`) and via genuine concurrent WorkerThreadPool
	# tasks (several chunks, each with its own pool context, actually
	# scheduled on real OS threads) -- comparing outputs catches cross-thread
	# corruption a purely single-threaded run never could.
	var pool := GamebryoResolverPool.new(4)
	var chunk_count := 4
	var chunk_size := int(ceil(float(refs.size()) / chunk_count))
	var task_ids: Array = []
	var task_results: Array = []
	var task_contexts: Array = []
	for i in range(chunk_count):
		var chunk: Array = refs.slice(i * chunk_size, min((i + 1) * chunk_size, refs.size()))
		var task_ctx := pool.checkout()
		check(task_ctx != null, "checked out a pool context for chunk %d" % i)
		task_contexts.append(task_ctx)
		var holder := [null]
		task_results.append(holder)
		var task_id: int = WorkerThreadPool.add_task(func(): holder[0] = registry.resolve_tile(chunk, task_ctx))
		task_ids.append(task_id)

	for i in range(chunk_count):
		WorkerThreadPool.wait_for_task_completion(task_ids[i])
		pool.checkin(task_contexts[i])

	check(pool.get_checked_out_count() == 0, "every checked-out context was returned after its task completed")

	var threaded_results: Array = []
	for holder in task_results:
		threaded_results.append_array(holder[0])

	check(threaded_results.size() == results.size(),
			"threaded resolve produced the same number of results as the synchronous baseline (got %d, expected %d)" %
			[threaded_results.size(), results.size()])

	var threaded_by_kind := {}
	for r in threaded_results:
		var k: String = r["kind"]
		threaded_by_kind[k] = threaded_by_kind.get(k, 0) + 1
	check(threaded_by_kind == by_kind,
			"threaded resolve's kind counts exactly match the synchronous baseline (got %s, expected %s)" % [threaded_by_kind, by_kind])

	# Spot-check actual geometry content, not just kind labels -- a mesh
	# transform mismatch would indicate real cross-thread data corruption,
	# not just a miscount.
	var mismatch := false
	for i in range(min(results.size(), threaded_results.size())):
		var sync_r: Dictionary = results[i]
		var thread_r: Dictionary = threaded_results[i]
		if sync_r["kind"] != thread_r["kind"]:
			mismatch = true
			break
		if sync_r["kind"] == "visual" or sync_r["kind"] == "door":
			var sync_mesh: Array = sync_r["geometry"]["mesh_entries"]
			var thread_mesh: Array = thread_r["geometry"]["mesh_entries"]
			if sync_mesh.size() != thread_mesh.size():
				mismatch = true
				break
			for j in range(sync_mesh.size()):
				if not sync_mesh[j]["transform"].is_equal_approx(thread_mesh[j]["transform"]):
					mismatch = true
					break
	check(not mismatch, "per-placement geometry (mesh transforms) from the threaded run exactly matches the synchronous baseline, index for index")

	print("=== construct_from_resolved(): Node output matches build()'s own known counts ===")
	# Same cell, same known-good counts as test_object_registry.gd's own
	# registry.build() checks -- construct_from_resolved() must produce the
	# same Node shape build() does, just arriving there via resolve then
	# construct instead of doing both in one call.
	var construct_root := Node3D.new()
	construct_root.rotation_degrees.x = -90
	add_child(construct_root)
	var construct_by_class := {}
	var construct_built := 0
	for r in results:
		var node := registry.construct_from_resolved(r) # no batch -- every kind becomes a real Node here, including structural fallback
		if node == null:
			continue
		construct_root.add_child(node)
		construct_built += 1
		var cls: String = String(node.get_script().get_global_name()) if node.get_script() else node.get_class()
		construct_by_class[cls] = construct_by_class.get(cls, 0) + 1

	check(construct_built == 428, "428 non-skip placements became real Nodes (434 refs - 6 skip) (got %d)" % construct_built)
	check(construct_by_class.get("DoorNode", 0) == 2, "both doors became DoorNode (got %d)" % construct_by_class.get("DoorNode", 0))
	check(construct_by_class.get("ContainerNode", 0) == 11, "all 11 containers became ContainerNode (got %d)" % construct_by_class.get("ContainerNode", 0))
	check(construct_by_class.get("ActivatorNode", 0) == 7, "7 activators became ActivatorNode (got %d)" % construct_by_class.get("ActivatorNode", 0))
	check(construct_by_class.get("FurnitureNode", 0) == 14, "all 14 furniture became FurnitureNode (got %d)" % construct_by_class.get("FurnitureNode", 0))
	check(construct_by_class.get("LightNode", 0) == 25, "all 25 lights became LightNode (got %d)" % construct_by_class.get("LightNode", 0))
	check(construct_by_class.get("MarkerNode", 0) == 9, "all 9 markers became MarkerNode (got %d)" % construct_by_class.get("MarkerNode", 0))
	check(construct_by_class.get("MovableStaticNode", 0) == 8, "all 8 movable statics became MovableStaticNode (got %d)" % construct_by_class.get("MovableStaticNode", 0))
	check(construct_by_class.get("GamebryoVisual", 0) == 352, "all 352 structural-fallback placements became GamebryoVisual (got %d)" % construct_by_class.get("GamebryoVisual", 0))

	for r in results:
		if r["kind"] == "door":
			var node := registry.construct_from_resolved(r)
			check(node is DoorNode, "constructing a door result again produces a DoorNode")
			check(node.has_destination == (not r["destination"].is_empty()),
					"constructed DoorNode's has_destination matches the resolved destination's emptiness")

	print("=== construct_from_resolved() with a batch: structural fallback routes to DirectGeometryBatch, not a Node ===")
	var batch := DirectGeometryBatch.new()
	batch.init(self)
	var routed_to_batch := 0
	var routed_to_node := 0
	for r in results:
		if r["kind"] == "visual" and r.get("type_tag", "") == "":
			var node := registry.construct_from_resolved(r, batch)
			if node == null:
				routed_to_batch += 1
			else:
				routed_to_node += 1
	check(routed_to_batch == 352, "all 352 structural-fallback placements routed to the batch (no Node) when one is given (got %d)" % routed_to_batch)
	check(routed_to_node == 0, "none of them fell back to a Node once a batch was supplied (got %d)" % routed_to_node)
	# get_batched_placement_count() counts mesh ENTRIES (one placement can
	# have several submeshes), not placements -- just confirm it's nonzero
	# and at least the placement count, not an exact 352.
	check(batch.get_batched_placement_count() >= 352, "the batch recorded at least one mesh entry per routed placement (got %d for 352 placements)" % batch.get_batched_placement_count())
	batch.free_all()

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
