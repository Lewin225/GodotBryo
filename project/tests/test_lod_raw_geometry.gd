extends Node3D

# 2.12 step 4 -- GamebryoObjectRegistry._resolve_visual()/_resolve_lod_geometry()
# attaching a second, optional raw geometry block for a placement's own
# _lod.nif companion. See phases/2/12-distant-object-lod.md.

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

	# Same real placements spot-checked in enginedocs/lod.md and
	# test_visible_when_distant.gd -- Barracks01/02 are VWD-flagged with a
	# real _lod.nif companion; QuonsetHut/CraneStatic have the companion but
	# are NOT VWD-flagged.
	var vwd_true_models := ["barracks01", "barracks02"]
	var vwd_false_models := ["nvnellisquonsethut01", "cranestatic01"]

	var found_true := {}
	var found_false := {}
	for gx in range(-40, 40):
		for gy in range(-40, 40):
			if found_true.size() >= vwd_true_models.size() and found_false.size() >= vwd_false_models.size():
				break
			var cell: Dictionary = esm.find_exterior_cell(wrld_id, gx, gy)
			if cell.is_empty():
				continue
			var refs: Array = esm.get_cell_references(int(cell["form_id"]))
			for p in refs:
				var model: String = String(p.get("model", "")).to_lower()
				for m in vwd_true_models:
					if m in model and not found_true.has(m):
						found_true[m] = p
				for m in vwd_false_models:
					if m in model and not found_false.has(m):
						found_false[m] = p

	print("=== VWD-flagged placements with a real _lod.nif companion carry lod_geometry ===")
	for m in vwd_true_models:
		check(found_true.has(m), "found a real placement for %s" % m)
		if found_true.has(m):
			var p: Dictionary = found_true[m]
			var r: Dictionary = registry.resolve_placement(p, ctx, true)
			check(r["kind"] == "visual", "%s resolves as kind=visual (got %s)" % [m, r["kind"]])
			check(r.has("lod_geometry"), "%s's resolved result carries lod_geometry" % m)
			if r.has("lod_geometry"):
				var lod_geom: Dictionary = r["lod_geometry"]
				check(not lod_geom.get("mesh_entries", []).is_empty(), "%s's lod_geometry has real mesh_entries" % m)
				check(lod_geom.get("model_path", "").to_lower().ends_with("_lod.nif"), "%s's lod_geometry model_path is the _lod.nif companion (got %s)" % [m, lod_geom.get("model_path", "")])
			# Full-detail geometry is untouched by this addition.
			check(not r.get("geometry", {}).get("mesh_entries", []).is_empty(), "%s still resolves its own full-detail geometry too" % m)

	print("=== non-VWD placements with the same _lod.nif companion do NOT carry lod_geometry ===")
	for m in vwd_false_models:
		check(found_false.has(m), "found a real placement for %s" % m)
		if found_false.has(m):
			var p: Dictionary = found_false[m]
			var r: Dictionary = registry.resolve_placement(p, ctx, true)
			check(r["kind"] == "visual", "%s resolves as kind=visual (got %s)" % [m, r["kind"]])
			check(not r.has("lod_geometry"), "%s's resolved result does NOT carry lod_geometry (not VWD-flagged)" % m)

	print("=== attached regardless of full_detail band (both true and false gave the same VWD placement) ===")
	if found_true.has("barracks01"):
		var p: Dictionary = found_true["barracks01"]
		var r_full: Dictionary = registry.resolve_placement(p, ctx, true)
		var r_distant: Dictionary = registry.resolve_placement(p, ctx, false)
		check(r_full.has("lod_geometry") and r_distant.has("lod_geometry"),
				"a VWD placement carries lod_geometry whether resolved full_detail=true or false")

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
