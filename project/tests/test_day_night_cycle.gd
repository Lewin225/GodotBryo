## test_day_night_cycle.gd — Integration test for Day-Night Cycle
## Tests GameTimeManager, WeatherManager, and CelestialController together.
##
## Run with:
##   tools/Godot_v4.7.1-stable_linux.x86_64 --headless --path project tests/test_day_night_cycle.tscn

extends Node

const GameDataConfigScript := preload("res://game_data_config.gd")

var _pass := 0
var _fail := 0

func _ready() -> void:
	var config: Dictionary = GameDataConfigScript.resolve()
	var data_dir := String(config.get("data_dir", ""))
	if data_dir.is_empty():
		printerr("test_day_night_cycle: " + String(config.get("error", "no data_dir")))
		get_tree().quit(1)
		return

	var esm := EsmReader.new()
	if not esm.open(data_dir + GameDataConfigScript.ESM_FILE):
		printerr("test_day_night_cycle: failed to open ESM: " + esm.get_last_error())
		get_tree().quit(1)
		return

	# Setup components
	var gtm := GameTimeManager.new()
	var wm := WeatherManager.new()
	var cc := CelestialController.new()
	var sun := DirectionalLight3D.new()
	var world_env := WorldEnvironment.new()
	var env := Environment.new()

	add_child(gtm)
	add_child(wm)
	add_child(cc)
	add_child(sun)
	add_child(world_env)

	wm.configure(esm)
	cc.configure(sun, world_env, env, wm)

	# 1. Activate worldspace for WastelandNV
	var wrld_info: Dictionary = esm.find_worldspace_by_editor_id("WastelandNV")
	_check("WastelandNV exists", not wrld_info.is_empty())
	var wrld_id := int(wrld_info.get("form_id", 0))

	wm.activate_worldspace(wrld_id)
	_check("WeatherManager has climate", not wm.climate.is_empty())
	_check("WeatherManager has active weather_from", not wm.weather_from.is_empty())
	_check("WeatherManager has active weather_to", not wm.weather_to.is_empty())

	cc.set_exterior(true)
	_check("WorldEnvironment assigned after set_exterior", world_env.environment != null)

	# 2. Test CelestialController at Solar Noon (e.g. hour 13.0)
	gtm.set_time(13.0, 19, 9, 2281)
	cc.update(gtm.game_hour, wm.climate)

	_check("Sun is visible at noon", sun.visible)
	_check("Sun light_energy > 0 at noon", sun.light_energy > 0.5)
	# Check sun direction tilted down
	_check("Sun orientation at noon", sun.rotation_degrees.x < 0.0)

	# 3. Test CelestialController at Midnight (hour 0.0) -> Moonlight active
	gtm.set_time(0.0, 19, 9, 2281)
	cc.update(gtm.game_hour, wm.climate)

	_check("Moonlight active at midnight", sun.visible)
	_check("Moonlight dimmer than noon sun", sun.light_energy < 1.5)
	_check("Moonlight has positive energy", sun.light_energy > 0.1)

	# 4. Test WeatherManager color interpolation
	var sunrise_color := wm.get_interpolated_color(WeatherManager.COL_SKY_UPPER, WeatherManager.SLOT_SUNRISE, WeatherManager.SLOT_SUNRISE, 0.0)
	var night_color := wm.get_interpolated_color(WeatherManager.COL_SKY_UPPER, WeatherManager.SLOT_NIGHT, WeatherManager.SLOT_NIGHT, 0.0)
	_check("Sunrise sky color is valid", sunrise_color.a > 0.0)
	_check("Night sky color is valid", night_color.a > 0.0)
	# Night is typically darker than sunrise
	_check("Night sky is darker than sunrise sky", night_color.v <= sunrise_color.v + 0.1)

	# 5. Test Fog parameters calculation
	var day_fog := wm.get_fog_params(1.0)
	var night_fog := wm.get_fog_params(0.0)
	_check("Day fog near/far parsed", day_fog.has("near") and day_fog.has("far"))
	_check("Night fog near/far parsed", night_fog.has("near") and night_fog.has("far"))
	_check("Fog far is positive", float(day_fog["far"]) > 0.0)

	# Summary
	print("\ntest_day_night_cycle summary:")
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
