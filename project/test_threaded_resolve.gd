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

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
