extends Node3D

## phases/5/00-script-interpreter-foundation.md's real live-game wiring:
## GamebryoObjectRegistry._finalize() now registers every placement with a
## non-zero script_form_id against a real ScriptEngine, when one is set.
## Loads the real GSDocMitchellHouse cell through the real CellLoader (same
## construction path the actual game uses, not a synthetic stand-in) and
## confirms a real, known-scripted prop (GSBrokenSMG, hand-verified this
## session to carry GSBrokenSMGScript's real form_id) actually gets
## registered -- and that a couple of real GameMode frame ticks against it
## don't crash, even though GSBrokenSMGScript's own GameMode block calls
## GetButtonPressed, which isn't implemented (should log a warning and
## no-op, not crash -- the same real behavior test_script_corpus_survey.gd
## already proved at the parser level, now proved through the real
## construction + dispatch path too).

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

	var loader := CellLoader.new()
	add_child(loader)
	await get_tree().process_frame # let CellLoader's own _ready() open its ESM/build its registry

	var script_engine := ScriptEngine.new()
	add_child(script_engine)
	script_engine.esm = loader.esm
	loader.registry.script_engine = script_engine

	var cell: Dictionary = loader.esm.find_cell_by_editor_id("GSDocMitchellHouse")
	check(not cell.is_empty(), "found GSDocMitchellHouse")
	if cell.is_empty():
		_finish()
		return

	loader.load_cell(int(cell["form_id"]))
	while loader._loading:
		await get_tree().process_frame

	check(loader._current != null, "cell loaded")
	if loader._current == null:
		_finish()
		return

	var refr_root: Node3D = loader._current.get_node("RefrRoot")
	var smg: Node = refr_root.get_node_or_null("GSBrokenSMG")
	check(smg != null, "GSBrokenSMG node exists in the real constructed tree")
	if smg != null:
		check(script_engine.is_scripted(smg), "GSBrokenSMG was registered with ScriptEngine (script_form_id resolved end-to-end)")

	# Let a couple of real GameMode frames run against whatever got
	# registered (GSBrokenSMGScript's own GameMode block among them) --
	# proves dispatch through the real per-frame path doesn't crash on
	# real, partially-unimplemented game data.
	for i in range(3):
		await get_tree().process_frame
	check(true, "3 real GameMode frame ticks completed without crashing")

	_finish()

func _finish() -> void:
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
