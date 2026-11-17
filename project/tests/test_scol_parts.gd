extends Node3D

## SCOL parts: each ONAM is followed by one DATA holding every placement of
## that part, 28 bytes each. SCOLStripTopsPlanter (00174CEC, placed as REFR
## 00174D08 in WastelandNV) has 7 parts with 32 placements: 2, 13, 7, 1, 3, 2
## and 4 (read from its DATA sizes). EsmReader.get_scol_parts returns every
## placement, and EsmStaticCollectionNode builds a node for each.

const SCOL_FORM_ID := 0x00174CEC
const EXPECTED_BY_PART := {
	0x00000A4F: 2,
	0x00116509: 13,
	0x00111DA2: 7,
	0x00111DA1: 1,
	0x00111DA0: 3,
	0x00111D9F: 2,
	0x00166BA1: 4,
}
const EXPECTED_TOTAL := 32

var failures := 0


func check(condition: bool, message: String) -> void:
	print("  OK   " if condition else "  FAIL ", message)
	if not condition:
		failures += 1


func _ready() -> void:
	var esm_server = get_node("/root/EsmServer")
	if not esm_server.is_ready():
		await esm_server.esm_ready
	var parts: Array = esm_server.reader.get_scol_parts(SCOL_FORM_ID)
	check(parts.size() == EXPECTED_TOTAL, "SCOLStripTopsPlanter has %d placements (expected %d)" % [parts.size(), EXPECTED_TOTAL])
	var by_part := {}
	var positions := {}
	for part: Dictionary in parts:
		var base := int(part.get("base_form_id", 0))
		by_part[base] = int(by_part.get(base, 0)) + 1
		positions[part.get("position", Vector3.ZERO)] = true
	for base: int in EXPECTED_BY_PART:
		check(int(by_part.get(base, 0)) == EXPECTED_BY_PART[base], "part %08X placed %d times (expected %d)" % [base, by_part.get(base, 0), EXPECTED_BY_PART[base]])
	check(positions.size() == EXPECTED_TOTAL, "every placement has its own position (%d distinct)" % positions.size())

	var reference := StaticCollectionReference.new()
	reference.base_form_id = SCOL_FORM_ID
	reference.base = esm_server.get_base(SCOL_FORM_ID)
	reference.instance_id = "test_scol"
	var node := EsmStaticCollectionNode.new()
	add_child(node)
	node.reference = reference
	await get_tree().process_frame
	var built := 0
	for child in node.get_children():
		if child.has_meta("esm_generated"):
			built += 1
	check(built == EXPECTED_TOTAL, "EsmStaticCollectionNode builds %d part nodes (expected %d)" % [built, EXPECTED_TOTAL])
	print("ALL CHECKS PASSED" if failures == 0 else "FAILURES: %d" % failures)
	get_tree().quit(0 if failures == 0 else 1)
