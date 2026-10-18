extends Node

# RACE FaceGen blocks: every race in FalloutNV.esm carries a male and a female
# FGGS (50 floats), FGGA (30) and FGTS (50). FGGA is zero on every race and
# TestQACaucasian is zero throughout. Values checked against a scan of the ESM.

const CAUCASIAN := 0x00000019
const TEST_QA_CAUCASIAN := 0x00033184

var failures := 0


func _ready() -> void:
	var server = get_node("/root/EsmServer")
	if not server.is_ready():
		await server.esm_ready

	var race_count := 0
	var complete := 0
	var asymmetric_zero := 0
	for row in server.get_record_index():
		if String(row.get("record_type", "")) != "RACE":
			continue
		var race := server.get_base(int(row.get("form_id", 0))) as RaceBase
		if race == null:
			continue
		race_count += 1
		if _has_complete_facegen(race):
			complete += 1
		if _is_zero(race.male_facegen_geometry_asymmetric) and _is_zero(race.female_facegen_geometry_asymmetric):
			asymmetric_zero += 1
	_check(race_count == 22, "22 RACE records (got %d)" % race_count)
	_check(complete == race_count, "every race has both FaceGen blocks at full size (got %d)" % complete)
	_check(asymmetric_zero == race_count, "FGGA is zero on every race (got %d)" % asymmetric_zero)

	var caucasian := server.get_base(CAUCASIAN) as RaceBase
	_check(caucasian != null, "Caucasian resolves")
	if caucasian != null:
		_check(_starts_with(caucasian.facegen_geometry_symmetric(false), [0.548799, -0.368000, -0.315035]),
				"Caucasian male FGGS is the first block")
		_check(_starts_with(caucasian.facegen_geometry_symmetric(true), [-0.034911, -0.629877, -0.534889]),
				"Caucasian female FGGS is the second block")
		_check(_starts_with(caucasian.facegen_texture_symmetric(false), [0.019767, -0.265990, -0.794573]),
				"Caucasian male FGTS")
		_check(_starts_with(caucasian.facegen_texture_symmetric(true), [0.069284, 0.648425, -0.611050]),
				"Caucasian female FGTS")

	var test_qa := server.get_base(TEST_QA_CAUCASIAN) as RaceBase
	_check(test_qa != null and _is_zero(test_qa.male_facegen_geometry_symmetric) \
			and _is_zero(test_qa.female_facegen_texture_symmetric), "TestQACaucasian's FaceGen is zero")

	_finish()


func _has_complete_facegen(race: RaceBase) -> bool:
	for female in [false, true]:
		if race.facegen_geometry_symmetric(female).size() != 50:
			return false
		if race.facegen_geometry_asymmetric(female).size() != 30:
			return false
		if race.facegen_texture_symmetric(female).size() != 50:
			return false
	return true


func _is_zero(values: PackedFloat32Array) -> bool:
	for value in values:
		if value != 0.0:
			return false
	return true


func _starts_with(values: PackedFloat32Array, expected: Array) -> bool:
	if values.size() < expected.size():
		return false
	for i in expected.size():
		if absf(values[i] - float(expected[i])) > 0.000001:
			return false
	return true


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1


func _finish() -> void:
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: %d" % failures)
	get_tree().quit(1 if failures > 0 else 0)
