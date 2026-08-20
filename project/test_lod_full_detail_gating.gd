extends Node3D

# 2.12 step 3 — full_detail gating in resolve_placement()/resolve_tile(). See
# phases/2/12-distant-object-lod.md.

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
	var ctx := GamebryoResolveContext.new()

	var wrld: Dictionary = esm.find_worldspace_by_editor_id("WastelandNV")
	check(not wrld.is_empty(), "found WastelandNV")
	var wrld_id := int(wrld["form_id"])

	# A real tile known (enginedocs/lod.md's own survey) to contain at least
	# one VWD-flagged placement with a resolvable _lod.nif -- reuse the exact
	# search this task's own earlier investigation already did.
	var vwd_placement: Dictionary = {}
	var non_vwd_placements: Array = []
	for gx in range(-40, 5):
		for gy in range(-10, 10):
			if not vwd_placement.is_empty() and non_vwd_placements.size() >= 3:
				break
			var cell: Dictionary = esm.find_exterior_cell(wrld_id, gx, gy)
			if cell.is_empty():
				continue
			var cell_refs: Array = esm.get_cell_references(int(cell["form_id"]))
			for p in cell_refs:
				if bool(p.get("visible_when_distant", false)) and vwd_placement.is_empty():
					vwd_placement = p
				elif not bool(p.get("visible_when_distant", false)) and non_vwd_placements.size() < 3:
					non_vwd_placements.append(p)
	check(not vwd_placement.is_empty(), "found a real VWD-flagged placement to test against")
	check(non_vwd_placements.size() > 0, "found real non-VWD placements to test against")

	print("=== full_detail=true (default): behaves exactly as before, nothing skipped by this gate ===")
	if not vwd_placement.is_empty():
		var r: Dictionary = registry.resolve_placement(vwd_placement, ctx, true)
		check(r["kind"] != "skip", "VWD placement resolves normally under full_detail=true")
	for p in non_vwd_placements:
		var r: Dictionary = registry.resolve_placement(p, ctx, true)
		check(r["kind"] != "skip" or p.get("model", "") == "", "non-VWD placement resolves normally under full_detail=true (unless it genuinely has no model)")

	print("=== full_detail=false: only the VWD-flagged placement resolves, everything else skips ===")
	if not vwd_placement.is_empty():
		var r: Dictionary = registry.resolve_placement(vwd_placement, ctx, false)
		check(r["kind"] != "skip", "VWD-flagged placement still resolves under full_detail=false")
	for p in non_vwd_placements:
		var r: Dictionary = registry.resolve_placement(p, ctx, false)
		check(r["kind"] == "skip", "non-VWD placement skips under full_detail=false (got kind=%s)" % r["kind"])

	print("=== resolve_tile() threads full_detail through to every placement ===")
	# A deliberately mixed list (real VWD placement + real non-VWD ones,
	# regardless of which cell each happened to come from) -- more robust
	# than relying on any single cell naturally containing both, which
	# isn't guaranteed (a tile can easily be all-VWD or all-non-VWD).
	var mixed_refs: Array = non_vwd_placements.duplicate()
	if not vwd_placement.is_empty():
		mixed_refs.append(vwd_placement)
	if not mixed_refs.is_empty():
		var results_distant: Array = registry.resolve_tile(mixed_refs, ctx, false)
		var results_full: Array = registry.resolve_tile(mixed_refs, ctx, true)
		check(results_distant.size() == mixed_refs.size(), "resolve_tile() still returns one result per ref under full_detail=false")
		var skip_count_distant := 0
		var skip_count_full := 0
		for r in results_distant:
			if r["kind"] == "skip":
				skip_count_distant += 1
		for r in results_full:
			if r["kind"] == "skip":
				skip_count_full += 1
		check(skip_count_distant > skip_count_full, "the distant-only pass skips strictly more placements than the full pass (got %d vs %d)" % [skip_count_distant, skip_count_full])

	print("=== SCOL parts still resolve fully once the SCOL itself passes the gate ===")
	var scol_cell: Dictionary = esm.find_cell_by_editor_id("SLGoldMine01INT")
	if not scol_cell.is_empty():
		var scol_refs: Array = esm.get_cell_references(int(scol_cell["form_id"]))
		var scol_placement: Dictionary = {}
		for p in scol_refs:
			if p.get("base_type", "") == "SCOL":
				scol_placement = p
				break
		check(not scol_placement.is_empty(), "found a real SCOL placement")
		if not scol_placement.is_empty():
			# Force it through as if VWD-flagged and in the distant band, to
			# isolate testing the part-resolution behavior specifically --
			# real SCOL VWD status varies and isn't the point of this check.
			scol_placement["visible_when_distant"] = true
			var r: Dictionary = registry.resolve_placement(scol_placement, ctx, false)
			check(r["kind"] == "scol", "the SCOL itself resolves (kind=scol) under full_detail=false when VWD-flagged")
			var any_part_skipped := false
			for part_result in r.get("parts", []):
				if part_result["kind"] == "skip":
					any_part_skipped = true
			check(not any_part_skipped, "no SCOL part was skipped, despite full_detail=false and parts having no VWD flag of their own")

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
