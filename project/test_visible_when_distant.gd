extends Node3D

# 2.12 step 1 — "Visible When Distant" REFR flag exposure. See
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
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")

	var wrld: Dictionary = esm.find_worldspace_by_editor_id("WastelandNV")
	check(not wrld.is_empty(), "found WastelandNV")
	var wrld_id := int(wrld["form_id"])

	# Same real placements spot-checked directly (bypassing GDScript) in
	# enginedocs/lod.md -- Barracks01/02 are VWD-flagged, NVNellisQuonsetHut
	# and CraneStatic01 are not, despite all of them having a real _lod.nif
	# companion. Search a wide area for each so this doesn't depend on
	# hardcoded FormIDs that could shift with a different ESM.
	var vwd_true_models := ["barracks01", "barracks02"]
	var vwd_false_models := ["nvnellisquonsethut01", "nvnellisquonsethut02", "cranestatic01"]

	var found_true := {}
	var found_false := {}
	for gx in range(-40, 40):
		for gy in range(-40, 40):
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

	print("=== VWD-flagged placements (Barracks01/02) ===")
	for m in vwd_true_models:
		check(found_true.has(m), "found a real placement for %s" % m)
		if found_true.has(m):
			var p: Dictionary = found_true[m]
			check(p.has("visible_when_distant"), "placement dict carries a visible_when_distant key")
			check(bool(p.get("visible_when_distant", false)), "%s is VWD-flagged, as confirmed in enginedocs/lod.md" % m)

	print("=== non-VWD placements with a real _lod.nif companion (QuonsetHut/CraneStatic) ===")
	for m in vwd_false_models:
		check(found_false.has(m), "found a real placement for %s" % m)
		if found_false.has(m):
			var p: Dictionary = found_false[m]
			check(not bool(p.get("visible_when_distant", true)), "%s is NOT VWD-flagged, as confirmed in enginedocs/lod.md" % m)

	print("=== SCOL parts never carry visible_when_distant=true (no REFR of their own) ===")
	var scol_cell: Dictionary = esm.find_cell_by_editor_id("SLGoldMine01INT")
	if not scol_cell.is_empty():
		var scol_refs: Array = esm.get_cell_references(int(scol_cell["form_id"]))
		for p in scol_refs:
			if p.get("base_type", "") == "SCOL":
				var parts: Array = esm.get_scol_parts(int(p.get("base_form_id", 0)))
				for part in parts:
					check(part.has("visible_when_distant") and not bool(part["visible_when_distant"]),
							"SCOL part defaults to visible_when_distant=false")
				break

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
