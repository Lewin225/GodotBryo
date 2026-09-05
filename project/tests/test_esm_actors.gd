extends Node

# Issue #52 chunk 1: real-data verification that EsmReader.get_cell_actors()
# resolves ACHR (placed NPC_) and ACRE (placed CREA) the same way
# get_cell_references() resolves REFR -- see EsmFile::get_cell_actors() in
# native/src/esm/esm_file.cpp and native/tools/esm_actor_survey.cpp for the
# equivalent native-side check. Deliberately native parsing only: no
# rendering, no GamebryoActor -- that's chunk 3+ of issue #52's plan.

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

	# Goodsprings exterior (-17, 0): independently known (test_phase1_integration.gd's
	# own census check) to contain a genuine ACRE (creature) but no ACHR.
	var wrld: Dictionary = esm.find_worldspace_by_editor_id("WastelandNV")
	check(not wrld.is_empty(), "found WastelandNV worldspace")
	if not wrld.is_empty():
		var cell: Dictionary = esm.find_exterior_cell(int(wrld["form_id"]), -17, 0)
		check(not cell.is_empty(), "found Goodsprings (-17,0) cell")
		if not cell.is_empty():
			var actors: Array = esm.get_cell_actors(int(cell["form_id"]))
			var acre_count := 0
			for a in actors:
				if a["base_type"] == "CREA":
					acre_count += 1
					check(String(a["editor_id"]) == "NVCrRaven", "Goodsprings ACRE base resolves to the real NVCrRaven CREA")
					check((a["position"] as Vector3).length() > 0.0, "ACRE has a real non-zero position")
			check(acre_count > 0, "found at least one real ACRE (creature) placement (%d)" % acre_count)

	# GSDocMitchellHouse: should contain Doc Mitchell as a real ACHR.
	var house: Dictionary = esm.find_cell_by_editor_id("GSDocMitchellHouse")
	check(not house.is_empty(), "found GSDocMitchellHouse cell")
	if not house.is_empty():
		var actors: Array = esm.get_cell_actors(int(house["form_id"]))
		var found_doc := false
		for a in actors:
			if a["base_type"] == "NPC_" and String(a["editor_id"]) == "DocMitchell":
				found_doc = true
				check((a["position"] as Vector3).length() > 0.0, "Doc Mitchell ACHR has a real non-zero position")
		check(found_doc, "found Doc Mitchell as a real ACHR resolving to NPC_")

	# get_cell_references() must stay REFR-only -- ACHR/ACRE should never
	# leak into it (this is the exact exclusion test_phase1_integration.gd's
	# own census check already covers from the other direction).
	if not house.is_empty():
		var refs: Array = esm.get_cell_references(int(house["form_id"]))
		var leaked := false
		for r in refs:
			if r["base_type"] == "NPC_" or r["base_type"] == "CREA":
				leaked = true
		check(not leaked, "get_cell_references() never returns NPC_/CREA -- those stay behind get_cell_actors()")

	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
