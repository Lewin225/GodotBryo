## test_game_time.gd — headless pass/fail test for GameTimeManager.
## Run with:
##   tools/Godot_v4.7.1-stable_linux.x86_64 --headless --path project tests/test_game_time.tscn

extends Node

var _pass := 0
var _fail := 0

func _ready() -> void:
	var gtm := GameTimeManager.new()
	add_child(gtm)

	# --- basic defaults ---
	_check("default hour",    absf(gtm.game_hour - 12.0) < 0.001)
	_check("default day",     gtm.game_day == 19)
	_check("default month",   gtm.game_month == 9)   # October (0-based)
	_check("default year",    gtm.game_year == 2281)
	_check("default timescale", absf(gtm.timescale - 30.0) < 0.001)

	# --- set_time ---
	gtm.set_time(6.5, 1, 0, 2282)
	_check("set_time hour",  absf(gtm.game_hour - 6.5) < 0.001)
	_check("set_time day",   gtm.game_day == 1)
	_check("set_time month", gtm.game_month == 0)
	_check("set_time year",  gtm.game_year == 2282)

	# --- advance_hours basic ---
	gtm.set_time(23.0, 31, 0, 2282)   # Jan 31, 11 PM
	gtm.advance_hours(2.0)             # crosses midnight → Feb 1
	_check("advance_hours crosses day",   gtm.game_day == 1)
	_check("advance_hours crosses month", gtm.game_month == 1)    # February
	_check("advance_hours new hour",      absf(gtm.game_hour - 1.0) < 0.001)

	# --- month rollover December → January ---
	gtm.set_time(23.5, 31, 11, 2282)  # Dec 31
	gtm.advance_hours(1.0)
	_check("year rollover month",  gtm.game_month == 0)
	_check("year rollover year",   gtm.game_year == 2283)
	_check("year rollover day",    gtm.game_day == 1)

	# --- formatted strings ---
	gtm.set_time(13.5, 19, 9, 2281)
	var dt := gtm.get_formatted_datetime()
	_check("formatted date contains 2281",    "2281" in dt)
	_check("formatted time contains PM",       "PM" in dt)

	# --- consume_seconds_passed ---
	gtm.set_time(12.0, 19, 9, 2281)
	gtm.timescale = 30.0
	gtm._process(1.0)   # 1 real second → 30 game seconds
	var secs := gtm.consume_seconds_passed()
	_check("consume_seconds_passed > 0", secs > 0.0)
	_check("consume_seconds_drains", absf(gtm.consume_seconds_passed()) < 0.001)

	# --- ESM-backed GLOB loading (cleanroom verification) ---
	var config: Dictionary = preload("res://game_data_config.gd").resolve()
	var data_dir := String(config.get("data_dir", ""))
	if not data_dir.is_empty():
		var esm := EsmReader.new()
		if esm.open(data_dir + "FalloutNV.esm"):
			# Query raw GLOBs
			var g_hour := esm.get_global_variable(0x38)
			_check("GLOB 0x38 GameHour found", not g_hour.is_empty())
			_check("GLOB 0x38 EDID=GameHour", g_hour.get("editor_id", "") == "GameHour")
			_check("GLOB 0x38 FLTV=12.0", absf(float(g_hour.get("value", 0.0)) - 12.0) < 0.001)

			var g_scale := esm.find_global_by_editor_id("TimeScale")
			_check("find_global_by_editor_id TimeScale found", not g_scale.is_empty())
			_check("TimeScale FormID=0x3a", int(g_scale.get("form_id", 0)) == 0x3a)
			_check("TimeScale value=30.0", absf(float(g_scale.get("value", 0.0)) - 30.0) < 0.001)

			var g_year := esm.get_global_variable(0x35)
			_check("GLOB 0x35 GameYear=2281", int(g_year.get("value", 0)) == 2281)

			# Test GameTimeManager.configure(esm)
			var esm_gtm := GameTimeManager.new()
			add_child(esm_gtm)
			esm_gtm.configure(esm)
			_check("configure() loads ESM hour", absf(esm_gtm.game_hour - 12.0) < 0.001)
			_check("configure() loads ESM year", esm_gtm.game_year == 2281)
			_check("configure() loads ESM month", esm_gtm.game_month == 9)
			_check("configure() loads ESM day (18+1=19)", esm_gtm.game_day == 19)
			_check("configure() loads ESM timescale", absf(esm_gtm.timescale - 30.0) < 0.001)
			_check("configure() loads ESM days_passed", absf(esm_gtm.game_days_passed - 5.0) < 0.001)

	# --- summary ---
	print("\ntest_game_time summary:")
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
