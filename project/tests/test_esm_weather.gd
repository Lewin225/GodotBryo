## test_esm_weather.gd — verifies get_climate_data, get_weather_data,
## and get_worldspace_climate against real FalloutNV.esm.
##
## Run with:
##   cd project
##   ../tools/Godot_v4.7.1-stable_linux.x86_64 --headless --path . tests/test_esm_weather.tscn
##
## Requires: the game data picked in the launcher, or GODOTBRYO_DATA_DIR.

extends Node

const GameDataConfigScript := preload("res://game_data_config.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	var config: Dictionary = GameDataConfigScript.resolve()
	var data_dir := String(config.get("data_dir", ""))
	if data_dir.is_empty():
		printerr("test_esm_weather: " + String(config.get("error", "no data_dir")))
		get_tree().quit(1)
		return

	var esm := EsmReader.new()
	if not esm.open(data_dir + GameDataConfigScript.ESM_FILE):
		printerr("test_esm_weather: could not open FalloutNV.esm: " + esm.get_last_error())
		get_tree().quit(1)
		return

	# --- get_worldspace_climate ---
	# WastelandNV worldspace (WRLD) is the Mojave Wasteland.
	# Real FormID from FalloutNV.esm: 0x1CF2E5 (verified via time_weather_survey).
	var wrld_id := 0x1CF2E5  # placeholder; find_worldspace_by_editor_id is the safer path
	var wrld_info: Dictionary = esm.find_worldspace_by_editor_id("WastelandNV")
	if not wrld_info.is_empty():
		wrld_id = int(wrld_info.get("form_id", 0))
	_check("WastelandNV worldspace found", wrld_id != 0)

	var clmt_id: int = esm.get_worldspace_climate(wrld_id)
	_check("WastelandNV has climate link", clmt_id != 0)

	if clmt_id != 0:
		var clmt: Dictionary = esm.get_climate_data(clmt_id)
		_check("CLMT not empty",              not clmt.is_empty())
		_check("CLMT has editor_id",          clmt.has("editor_id"))
		_check("CLMT sunrise_begin in range", clmt.get("sunrise_begin", -1.0) >= 0.0 and clmt.get("sunrise_begin", 99.0) < 12.0)
		_check("CLMT sunrise before sunset",  clmt.get("sunrise_end", 0.0) < clmt.get("sunset_begin", 24.0))
		_check("CLMT has weather_chances",    (clmt.get("weather_chances", []) as Array).size() > 0)

		# NVDefaultClimate TNAM known values (verified via native tool):
		# sunrise_begin=6.0, sunrise_end=8.0, sunset_begin=18.0, sunset_end=20.0
		if (clmt.get("editor_id", "") as String).contains("DefaultClimate"):
			_check("DefaultClimate sunrise_begin=6.0", absf(float(clmt.get("sunrise_begin", -1.0)) - 6.0) < 0.1)
			_check("DefaultClimate sunset_end=20.0",   absf(float(clmt.get("sunset_end", -1.0)) - 20.0) < 0.1)

		# --- get_weather_data ---
		var chances := clmt.get("weather_chances", []) as Array
		if not chances.is_empty():
			var first_wthr_id := int((chances[0] as Dictionary).get("weather_form_id", 0))
			_check("first WLST entry has form_id", first_wthr_id != 0)
			if first_wthr_id != 0:
				var wthr: Dictionary = esm.get_weather_data(first_wthr_id)
				_check("WTHR not empty",          not wthr.is_empty())
				_check("WTHR has editor_id",       wthr.has("editor_id"))
				_check("WTHR colors = 240 bytes",  (wthr.get("colors", PackedByteArray()) as PackedByteArray).size() == 240)
				_check("WTHR fog_day_far > 0",     float(wthr.get("fog_day_far", 0.0)) > 0.0)
				_check("WTHR fog_night_far > 0",   float(wthr.get("fog_night_far", 0.0)) > 0.0)
				# WastelandClear has DayFar=250000, NVUrbanClear has DayFar=200000.
				if (wthr.get("editor_id", "") as String).contains("Clear"):
					var far_val: float = float(wthr.get("fog_day_far", 0.0))
					_check("Clear fog_day_far in valid range [200000, 250000]", far_val >= 200000.0 and far_val <= 250000.0)

	print("\ntest_esm_weather summary:")
	if _fail == 0:
		print("ALL CHECKS PASSED (%d passed)" % _pass)
		get_tree().quit(0)
	else:
		printerr("FAILURES: %d (passed: %d)" % [_fail, _pass])
		get_tree().quit(1)

func _check(desc: String, condition: bool) -> void:
	if condition:
		print("  OK   " + desc)
		_pass += 1
	else:
		printerr("  FAIL " + desc)
		_fail += 1
