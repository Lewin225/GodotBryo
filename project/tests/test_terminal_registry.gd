extends Node

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"
const FIXTURE_CELL := "HooverDamIntPowerPlant01b"
const FIXTURE_TERM := 0x166B56 # VHDStealthSuitTerminal

var failures := 0

func check(ok: bool, message: String) -> void:
	print("  OK   " if ok else "  FAIL ", message)
	if not ok:
		failures += 1

func _fixture_placement(esm: EsmReader) -> Dictionary:
	var cell: Dictionary = esm.find_cell_by_editor_id(FIXTURE_CELL)
	for placement in esm.get_cell_references(int(cell.get("form_id", 0))):
		if int(placement.get("base_form_id", 0)) == FIXTURE_TERM:
			return placement
	return {}

func assert_terminal(node: Node3D, label: String) -> void:
	check(node is TerminalNode, "%s constructs a TerminalNode" % label)
	if not node is TerminalNode:
		return
	check(String(node.terminal_data.get("editor_id", "")) == "VHDStealthSuitTerminal", "%s retains parsed TERM identity" % label)
	var items: Array = node.terminal_data.get("items", [])
	check(items.size() == 3, "%s retains ordered authored menu items" % label)
	if items.size() == 3:
		check(int(items[0].get("note_form_id", 0)) == 0x166B67, "%s retains the INAM Note FormID" % label)

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(DATA_DIR + "FalloutNV.esm"), "opened FalloutNV.esm")
	var placement := _fixture_placement(esm)
	check(not placement.is_empty(), "found the documented placed terminal fixture")
	if not placement.is_empty():
		var registry := GamebryoObjectRegistry.new(GamebryoMeshResolver.new(), esm)
		var direct := registry.build(placement)
		assert_terminal(direct, "CellLoader/editor path")
		if direct != null:
			direct.free()

		var threaded := registry.construct_from_resolved(registry.resolve_placement(placement, GamebryoResolveContext.new()), null)
		assert_terminal(threaded, "WorldStreamer path")
		if threaded != null:
			threaded.free()
	_finish()

func _finish() -> void:
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
