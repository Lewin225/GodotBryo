extends Node3D

# 2.12 step 2 — LOD companion path derivation. See
# phases/2/12-distant-object-lod.md and enginedocs/lod.md.

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _ready() -> void:
	var resolver := GamebryoMeshResolver.new()

	print("=== real models confirmed (enginedocs/lod.md) to have a _lod.nif companion ===")
	var with_lod := [
		"architecture\\barracks\\barracks01.nif",
		"architecture\\barracks\\barracks02.nif",
		"architecture\\Nellis AFB\\NVNellisQuonsetHut01.nif",
		"architecture\\wasteland\\CraneStatic01.NIF",
	]
	for m in with_lod:
		var lod := resolver.lod_companion_path(m)
		check(lod != "", "%s resolves a real _lod.nif companion (got %s)" % [m, lod])
		if lod != "":
			check(lod.to_lower() == m.to_lower().replace(".nif", "_lod.nif"),
					"derived path matches the expected suffix-insertion shape (got %s)" % lod)

	print("=== a real placement's own model with no _lod.nif companion ===")
	# GSDocMitchellHouse's own placements (test_object_registry.gd's own
	# fixture) -- ordinary interior clutter, none of which is expected to
	# have a distant-LOD variant at all.
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")
	var cell: Dictionary = esm.find_cell_by_editor_id("GSDocMitchellHouse")
	check(not cell.is_empty(), "cell found")
	var refs: Array = esm.get_cell_references(int(cell["form_id"]))
	var checked_any := false
	var none_had_lod := true
	for p in refs:
		var model: String = p.get("model", "")
		if model == "":
			continue
		checked_any = true
		if resolver.lod_companion_path(model) != "":
			none_had_lod = false
			print("  (unexpected LOD companion found for interior clutter: ", model, ")")
	check(checked_any, "checked at least one real interior placement's model")
	check(none_had_lod, "no interior clutter model in this cell has a _lod.nif companion (expected)")

	print("=== non-.nif / empty input handled cleanly ===")
	check(resolver.lod_companion_path("") == "", "empty model_path returns empty, not a crash")
	check(resolver.lod_companion_path("textures\\something.dds") == "", "a non-.nif path returns empty")

	print("=== caching: repeat calls return the same cached result ===")
	var first := resolver.lod_companion_path(with_lod[0])
	var second := resolver.lod_companion_path(with_lod[0])
	check(first == second, "cached result is stable across repeat calls")

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
