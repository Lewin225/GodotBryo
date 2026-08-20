extends Node3D

# 2.10 step 2 — GamebryoResolverPool. See phases/2/10-threaded-streaming-workers.md.

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _ready() -> void:
	print("=== automatic sizing ===")
	var auto_pool := GamebryoResolverPool.new()
	check(auto_pool.get_size() >= 2, "automatic size is at least 2 (got %d)" % auto_pool.get_size())
	check(auto_pool.get_size() == maxi(2, OS.get_processor_count() - 1),
			"automatic size matches OS.get_processor_count()-1, floored at 2 (got %d, processor_count=%d)" %
			[auto_pool.get_size(), OS.get_processor_count()])
	check(auto_pool.get_available_count() == auto_pool.get_size(), "every instance starts available")
	check(auto_pool.get_checked_out_count() == 0, "nothing checked out initially")

	print("=== checkout/checkin exhaustion ===")
	var pool := GamebryoResolverPool.new(3)
	check(pool.get_size() == 3, "explicit size override honored (got %d)" % pool.get_size())

	var r1 := pool.checkout()
	var r2 := pool.checkout()
	var r3 := pool.checkout()
	check(r1 != null and r2 != null and r3 != null, "checked out all 3 instances")
	check(r1 != r2 and r2 != r3 and r1 != r3, "all 3 checked-out instances are distinct objects")
	check(pool.get_checked_out_count() == 3, "checked_out_count == 3 after 3 checkouts")
	check(pool.get_available_count() == 0, "available_count == 0 after exhausting the pool")

	var r4 := pool.checkout()
	check(r4 == null, "checkout() returns null once the pool is exhausted, not a new instance")

	pool.checkin(r2)
	check(pool.get_available_count() == 1, "available_count == 1 after one checkin")
	check(pool.get_checked_out_count() == 2, "checked_out_count == 2 after one checkin")

	var r5 := pool.checkout()
	check(r5 == r2, "checking out again after a checkin returns the just-returned instance")

	print("=== per-instance cache isolation ===")
	# Load the same NIF through two different pool instances -- if caches
	# were accidentally shared (e.g. a bug reusing one GamebryoMeshResolver
	# instead of constructing _size independent ones), the second load
	# would show as a cache hit on an instance that never loaded it before.
	var iso_pool := GamebryoResolverPool.new(2)
	var a := iso_pool.checkout()
	var b := iso_pool.checkout()
	check(a != b, "two distinct instances checked out for the isolation test")

	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")
	var cell: Dictionary = esm.find_cell_by_editor_id("GSDocMitchellHouse")
	check(not cell.is_empty(), "cell found")
	var refs: Array = esm.get_cell_references(int(cell["form_id"]))
	var model_path := ""
	for p in refs:
		var m: String = p.get("model", "")
		if m != "":
			model_path = m
			break
	check(model_path != "", "found a real placement with a model to test cache isolation against")

	if model_path != "":
		var nif_a := a.resolver.load_nif(model_path)
		check(nif_a != null, "instance A resolved the model")
		check(a.resolver.get_cache_stats()["unique_nifs_loaded"] == 1, "instance A's own cache shows 1 unique NIF loaded")
		check(b.resolver.get_cache_stats()["unique_nifs_loaded"] == 0, "instance B's cache is untouched by A's load (private caches, not shared)")

		var nif_b := b.resolver.load_nif(model_path)
		check(nif_b != null, "instance B independently resolved the same model")
		check(b.resolver.get_cache_stats()["unique_nifs_loaded"] == 1, "instance B's own cache now shows 1 unique NIF loaded, independent of A")
		check(nif_a != nif_b, "each instance parsed its own NifReader -- not sharing a cached object across instances")

	print("=== per-context EsmReader isolation ===")
	# GamebryoResolveContext bundles a private EsmReader alongside the
	# resolver (discovered necessary in step 3: DOOR/SCOL/LIGH resolution
	# reads the ESM directly, and EsmFile is exactly as not-thread-safe as
	# BsaArchive) -- confirm each context's esm is independently open and
	# not the same shared instance.
	check(a.esm != b.esm, "instance A and B each have their own EsmReader, not a shared one")
	check(a.esm != esm and b.esm != esm, "pool contexts never reuse this test's own EsmReader")
	var door_cell: Dictionary = a.esm.find_cell_by_editor_id("GSDocMitchellHouse")
	check(not door_cell.is_empty(), "instance A's own EsmReader independently resolves real ESM data")

	print("=== cross-context cache merge (checkin -> shared -> checkout) ===")
	# x resolves a model and is checked back in (folding its cache into the
	# pool's shared resolver); y -- a DIFFERENT context that never itself
	# resolved anything -- should come back from a later checkout() already
	# warm with that same model, without ever touching x's cache directly.
	if model_path != "":
		var merge_pool := GamebryoResolverPool.new(2)
		var x := merge_pool.checkout()
		var y := merge_pool.checkout()
		var nif_x := x.resolver.load_nif(model_path)
		check(nif_x != null, "x resolved the model")
		check(y.resolver.get_cache_stats()["unique_nifs_loaded"] == 0, "y hasn't resolved anything yet")

		merge_pool.checkin(x) # folds x's cache into the pool's shared resolver
		merge_pool.checkin(y) # y itself has nothing new to contribute
		check(merge_pool.get_shared_cache_stats()["unique_nifs_loaded"] >= 1,
				"the pool's shared resolver picked up x's resolved NIF on checkin")

		var z := merge_pool.checkout() # LIFO -- returns y (checked in last)
		check(z == y, "sanity: this checkout returns y, the context that never itself resolved the model")
		check(z.resolver.get_cache_stats()["unique_nifs_loaded"] == 1,
				"y comes back from checkout() already warm with x's resolved model, despite never resolving it itself")
		check(z.resolver.load_nif(model_path) == nif_x,
				"y's load_nif() returns the SAME cached NifReader object x built -- no re-parse, no duplicate object")

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
