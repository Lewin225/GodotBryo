extends Node

## Issue #12's native ESM contract test.  These are real vanilla fixtures,
## selected from grass_survey.cpp rather than synthetic GRAS/LTEX records.

var ESM_PATH: String = GameDataConfig.resolve()["data_dir"] + GameDataConfig.ESM_FILE
var failures := 0

func check(condition: bool, message: String) -> void:
	if condition:
		print("  OK   ", message)
	else:
		print("  FAIL ", message)
		failures += 1

func _ready() -> void:
	var esm := EsmReader.new()
	check(esm.open(ESM_PATH), "opened FalloutNV.esm")
	if esm.get_last_error() != "":
		_finish()
		return

	var grass: Dictionary = esm.get_grass_data(0x17753) # GrassWasteland01
	check(String(grass.get("editor_id", "")) == "GrassWasteland01", "GRAS EDID resolves")
	check(String(grass.get("model_path", "")) == "Landscape\\Grass\\GrassWasteland01.NIF", "GRAS MODL resolves")
	check(int(grass.get("density", -1)) == 30, "DATA density is compact byte 30")
	check(int(grass.get("min_slope", -1)) == 0 and int(grass.get("max_slope", -1)) == 40, "DATA slope byte range is 0..40")
	check(is_equal_approx(float(grass.get("position_range", 0.0)), 22.0), "DATA position range float resolves")
	check(is_equal_approx(float(grass.get("height_range", 0.0)), 0.35), "DATA height range float resolves")
	check(is_equal_approx(float(grass.get("color_range", 0.0)), 0.1), "DATA colour range float resolves")
	check(is_equal_approx(float(grass.get("wave_period", 0.0)), 15.0), "DATA wave period float resolves")
	check(int(grass.get("flags", 0)) == 6, "DATA flags preserve uniform-scaling and fit-to-slope")

	var linked: Array = esm.get_ltex_grass_form_ids(0x357BE) # ScrubBarrenWastes01
	check(linked == [0x17753, 0x2A4C1, 0x2A4C2], "LTEX.GNAM returns all three authored GRAS links in order")
	_finish()

func _finish() -> void:
	print("=======================")
	if failures == 0:
		print("ALL CHECKS PASSED")
	else:
		print("FAILURES: ", failures)
	get_tree().quit(1 if failures > 0 else 0)
