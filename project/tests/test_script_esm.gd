extends Node

const ESM_PATH := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/FalloutNV.esm"

var failures := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  OK   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1

func _ready() -> void:
	print("--- SCPT / script data (phases/5/00-script-interpreter-foundation.md) ---")
	var reader := EsmReader.new()
	var opened := reader.open(ESM_PATH)
	check(opened, "open() succeeded (error: %s)" % reader.get_last_error())
	if not opened:
		_finish()
		return

	# Hand-verified this session via a native scratch tool against real
	# FalloutNV.esm bytes -- form_id 0x17b787.
	var script: Dictionary = reader.get_script_data(0x17b787)
	check(not script.is_empty(), "VLCSafetyTrigger01SCRIPT resolved")
	if not script.is_empty():
		check(String(script["editor_id"]) == "VLCSafetyTrigger01SCRIPT", "editor_id matches")
		check(int(script["script_type"]) == 0, "script_type is Object (0)")
		check(String(script["source_text"]).begins_with("scn VLCSafetyTrigger01SCRIPT"), "source_text starts with real scn header")
		check(String(script["source_text"]).find("BEGIN OnTriggerEnter") != -1, "source_text contains a real BEGIN block")

		var locals: Array = script["locals"]
		check(locals.size() == 1, "exactly one local variable (got %d)" % locals.size())
		if locals.size() == 1:
			check(String(locals[0]["name"]) == "ActivatorREF", "local variable name matches")

		var refs: PackedInt64Array = script["referenced_form_ids"]
		check(refs.size() == 12, "12 referenced FormIDs (got %d)" % refs.size())
		check(refs.size() > 0 and int(refs[0]) == 0x14, "first referenced FormID matches (0x14)")

	print("--- SCRI on a real base record (ACTI/CONT carry a script FormID) ---")
	# GSDocMitchellHouse has real ACTI placements -- confirm at least one
	# resolves a non-zero script_form_id through get_cell_references().
	var cell: Dictionary = reader.find_cell_by_editor_id("GSDocMitchellHouse")
	check(not cell.is_empty(), "found GSDocMitchellHouse")
	if not cell.is_empty():
		var refs: Array = reader.get_cell_references(int(cell["form_id"]))
		var any_scripted := false
		for pl in refs:
			if int(pl.get("script_form_id", 0)) != 0:
				any_scripted = true
				break
		check(any_scripted, "at least one REFR in GSDocMitchellHouse resolves a non-zero script_form_id")

	_finish()

func _finish() -> void:
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
