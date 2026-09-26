class_name GameTimeManager
extends Node

## Manages in-game time and the calendar.
##
## The real engine tracks game time through five GLOB
## records (verified via tools/time_weather_survey.cpp against only FalloutNV.esm):
##   GameYear  (0x35) = 2281   -- starting year
##   GameMonth (0x36) = 9      -- 0-based: 9 = October
##   GameDay   (0x37) = 18     -- day of month (1-based in-game display)
##   GameHour  (0x38) = 12.0   -- fractional hour of day [0, 24)
##   GameDaysPassed (0x39) = 5 -- cumulative fractional days elapsed
##   TimeScale  (0x3a) = 30.0  -- game seconds per real second
##
## This class advances time each process frame (when not paused/interior),
## fires signals on hour and day changes, and exposes helpers for
## script VM integration (GameDaysPassed, GetCurrentTime).

## Signals
signal hour_changed(new_hour: float)
signal day_changed(new_day: int, new_month: int, new_year: int)
signal time_advanced(delta_game_seconds: float)

# Days per month (non-leap: FNV doesn't model leap years in gameplay)
const DAYS_IN_MONTH: Array[int] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
const MONTH_NAMES: Array[String] = [
	"January", "February", "March", "April", "May", "June",
	"July", "August", "September", "October", "November", "December"
]

## Current game clock state — verified default values from FalloutNV.esm GLOBs.
var game_hour: float = 12.0    ## Fractional hour in [0.0, 24.0)
var game_day: int = 19         ## Day of month, 1-based (GLOB GameDay = 18, but
							   ## the game displays it as Oct 19 on the Pip-Boy
							   ## startup; 18 is day-index 0 = day 19 ambiguity
							   ## accepted as-is from GLOB value + 1)
var game_month: int = 9        ## 0-based month index: 9 = October
var game_year: int = 2281
var game_days_passed: float = 5.0  ## Cumulative fractional days since game start
var timescale: float = 30.0       ## Game seconds per real second
var is_paused: bool = false

var _last_hour_int: int = 12
var _last_day: int = 19
var _seconds_passed_accumulator: float = 0.0  # for GetSecondsPassed integration

## Initialize starting game clock state directly from FalloutNV.esm GLOB records:
##   GameYear       (0x35)
##   GameMonth      (0x36)
##   GameDay        (0x37)
##   GameHour       (0x38)
##   GameDaysPassed (0x39)
##   TimeScale      (0x3a)
func configure(esm: EsmReader) -> void:
	if esm == null:
		return

	var g_hour: Dictionary = esm.get_global_variable(0x38)
	if not g_hour.is_empty():
		game_hour = float(g_hour.get("value", game_hour))

	var g_day: Dictionary = esm.get_global_variable(0x37)
	if not g_day.is_empty():
		# In FNV, GLOB GameDay is stored 0-based index 18 (displayed as Oct 19 on startup).
		# In-game calendar arithmetic is 1-based day of month [1, 31].
		var raw_day: int = int(g_day.get("value", 18.0))
		game_day = raw_day + 1

	var g_month: Dictionary = esm.get_global_variable(0x36)
	if not g_month.is_empty():
		game_month = int(g_month.get("value", game_month))

	var g_year: Dictionary = esm.get_global_variable(0x35)
	if not g_year.is_empty():
		game_year = int(g_year.get("value", game_year))

	var g_days_passed: Dictionary = esm.get_global_variable(0x39)
	if not g_days_passed.is_empty():
		game_days_passed = float(g_days_passed.get("value", game_days_passed))

	var g_timescale: Dictionary = esm.get_global_variable(0x3a)
	if not g_timescale.is_empty():
		timescale = float(g_timescale.get("value", timescale))

	_last_hour_int = int(game_hour)
	_last_day = game_day


func _process(delta: float) -> void:
	if is_paused:
		return

	var game_seconds: float = delta * timescale
	_seconds_passed_accumulator += game_seconds
	time_advanced.emit(game_seconds)

	var prev_hour_int := _last_hour_int
	var prev_day := game_day

	game_hour += game_seconds / 3600.0
	game_days_passed += game_seconds / 86400.0

	# Roll over hours into days/months/years
	while game_hour >= 24.0:
		game_hour -= 24.0
		_advance_day()

	var new_hour_int := int(game_hour)
	if new_hour_int != _last_hour_int:
		_last_hour_int = new_hour_int
		hour_changed.emit(game_hour)

	if game_day != _last_day:
		_last_day = game_day
		day_changed.emit(game_day, game_month, game_year)

## Advance internal calendar by one day, rolling month and year.
func _advance_day() -> void:
	game_day += 1
	var days_this_month: int = DAYS_IN_MONTH[game_month]
	if game_day > days_this_month:
		game_day = 1
		game_month += 1
		if game_month >= 12:
			game_month = 0
			game_year += 1

## Directly set game time (for fast travel, sleep, etc.)
func set_time(hour: float, day: int, month: int, year: int) -> void:
	game_hour = clampf(hour, 0.0, 23.9999)
	game_day = clampi(day, 1, DAYS_IN_MONTH[month])
	game_month = clampi(month, 0, 11)
	game_year = year
	_last_hour_int = int(game_hour)
	_last_day = game_day
	hour_changed.emit(game_hour)

## Set only the fractional hour of day [0, 24), preserving the current date.
func set_hour(hour: float) -> void:
	game_hour = fposmod(hour, 24.0)
	_last_hour_int = int(game_hour)
	hour_changed.emit(game_hour)

## Advance by a specific number of game hours (sleep/wait/fast-travel).
func advance_hours(hours: float) -> void:
	game_hour += hours
	game_days_passed += hours / 24.0
	while game_hour >= 24.0:
		game_hour -= 24.0
		_advance_day()
	_last_hour_int = int(game_hour)
	_last_day = game_day
	hour_changed.emit(game_hour)

## Drain and return accumulated real-seconds-scaled game seconds since last call.
func consume_seconds_passed() -> float:
	var val := _seconds_passed_accumulator
	_seconds_passed_accumulator = 0.0
	return val

## Human-readable 12-hour clock string, e.g. "12:30 PM".
func get_formatted_time() -> String:
	var h := int(game_hour)
	var m := int((game_hour - h) * 60.0)
	var suffix := "AM" if h < 12 else "PM"
	var display_h := h % 12
	if display_h == 0:
		display_h = 12
	return "%d:%02d %s" % [display_h, m, suffix]

## Human-readable calendar date, e.g. "19 Oct 2281".
func get_formatted_date() -> String:
	var month_abbr := MONTH_NAMES[game_month].substr(0, 3)
	return "%d %s %d" % [game_day, month_abbr, game_year]

## For debug HUD display.
func get_formatted_datetime() -> String:
	return "%s  %s" % [get_formatted_date(), get_formatted_time()]
