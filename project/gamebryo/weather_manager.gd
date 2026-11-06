class_name WeatherManager
extends Node

## Manages weather state and transitions based on CLMT/WTHR ESM data.
##
## Holds the current worldspace's ClimateData (sunrise/sunset timing, weather
## list) and drives smooth transitions between weather presets over time.
## The WeatherManager does not touch the Environment resource directly —
## it exposes get_sky_color() / get_fog_params() / get_sun_color() helpers
## that CelestialController and game.gd consume each frame.
##
## Time-of-day slot convention (matches real NAM0 layout):
##   0 = Sunrise   1 = Day   2 = Sunset   3 = Night
##   4 = EarlySunrise (transition)   5 = LateSunset (transition)
##
## Color-type indices within each slot (matches real NAM0 layout):
##   0 SkyUpper  1 Fog  2 Unused  3 Ambient  4 Sunlight  5 Sun
##   6 Stars    7 SkyLower  8 Horizon  9 Unused

# Indices into the 10-type NAM0 color array
const COL_SKY_UPPER  := 0
const COL_FOG        := 1
const COL_UNUSED_2   := 2
const COL_AMBIENT   := 3
const COL_SUN_LIGHT := 4
const COL_SUN       := 5
const COL_STARS     := 6
const COL_SKY_LOWER := 7
const COL_HORIZON   := 8
const COL_UNUSED_9  := 9

# Time-of-day slot indices
const SLOT_SUNRISE := 0
const SLOT_DAY     := 1
const SLOT_SUNSET  := 2
const SLOT_NIGHT   := 3

## Transition duration in game-hours when switching weather presets.
const WEATHER_TRANSITION_HOURS := 2.0

var _esm: EsmReader = null

## Active climate data (from CLMT record).
var climate: Dictionary = {}
## Active weather data (from WTHR record). Two slots for cross-fade:
var weather_from: Dictionary = {}
var weather_to: Dictionary = {}
## Transition progress [0.0, 1.0]; 1.0 = fully in weather_to.
var blend_alpha: float = 1.0
## Set by load_state(): the next activate_worldspace() keeps the loaded
## weather instead of picking the climate's first.
var _keep_loaded_weather := false

func configure(esm: EsmReader) -> void:
	_esm = esm

## Load the CLMT for a given worldspace FormID and pick the initial weather.
func activate_worldspace(wrld_form_id: int) -> void:
	if _esm == null:
		return
	var clmt_id: int = _esm.get_worldspace_climate(wrld_form_id)
	if clmt_id == 0:
		push_warning("WeatherManager: worldspace %d has no CNAM climate link" % wrld_form_id)
		return
	climate = _esm.get_climate_data(clmt_id)
	if climate.is_empty():
		push_warning("WeatherManager: climate FormID 0x%x not found" % clmt_id)
		return
	# Pick a starting weather from the chance-weighted list, unless a save
	# has just set one.
	if _keep_loaded_weather:
		_keep_loaded_weather = false
		return
	_pick_initial_weather()

## Pick the initial weather deterministically (highest chance entry).
func _pick_initial_weather() -> void:
	var chances: Array = climate.get("weather_chances", [])
	if chances.is_empty():
		push_warning("WeatherManager: no weather_chances in climate")
		return
	# Sort descending by chance weight, take the first (most common) one.
	chances.sort_custom(func(a, b): return a["chance"] > b["chance"])
	var first_id: int = chances[0]["weather_form_id"]
	weather_from = _esm.get_weather_data(first_id)
	weather_to = weather_from
	blend_alpha = 1.0

## The weather as plain values for a save (SaveServer's `weather` section):
## the two WTHR records being blended, by `<file>:<local id>`, and the blend.
func save_state() -> Dictionary:
	return {
		"weather_from": _record_text(int(weather_from.get("form_id", 0))),
		"weather_to": _record_text(int(weather_to.get("form_id", 0))),
		"blend_alpha": blend_alpha,
	}

## Sets the weather from a save_state() result. The worldspace's climate is
## read when the player next enters it, which keeps this weather. A WTHR
## record not in the load order is dropped and listed in `report`.
func load_state(state: Dictionary, report: Array = []) -> void:
	if _esm == null:
		return
	for slot in ["weather_from", "weather_to"]:
		var text: Variant = state.get(slot)
		var form_id := EsmServer.form_id_for_instance_id(String(text)) if text != null else 0
		var weather: Dictionary = _esm.get_weather_data(form_id) if form_id != 0 else {}
		if text != null and weather.is_empty():
			report.append("dropped weather %s: not in the load order" % text)
		if slot == "weather_from":
			weather_from = weather
		else:
			weather_to = weather
	blend_alpha = float(state.get("blend_alpha", 1.0))
	_keep_loaded_weather = not weather_to.is_empty()

func _record_text(form_id: int) -> Variant:
	if form_id == 0:
		return null
	return String(EsmServer.instance_id_for_form_id(form_id))

## Set or transition to a specific weather preset by FormID.
func set_weather(wthr_form_id: int, instant: bool = true) -> void:
	if _esm == null:
		return
	var new_wthr: Dictionary = _esm.get_weather_data(wthr_form_id)
	if new_wthr.is_empty():
		push_warning("WeatherManager: cannot find weather 0x%x" % wthr_form_id)
		return
	if instant:
		weather_from = new_wthr
		weather_to = new_wthr
		blend_alpha = 1.0
	else:
		# Start a smooth crossfade from current weather to new weather
		if blend_alpha < 1.0 and not weather_to.is_empty():
			weather_from = weather_to
		weather_to = new_wthr
		blend_alpha = 0.0

## Returns all weather entries defined by the current climate with their editor IDs.
func get_climate_weather_list() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _esm == null:
		return result
	var chances: Array = climate.get("weather_chances", [])
	for entry in chances:
		var wid: int = int(entry.get("weather_form_id", 0))
		if wid == 0:
			continue
		var wdata: Dictionary = _esm.get_weather_data(wid)
		var edid: String = String(wdata.get("editor_id", "0x%x" % wid))
		result.push_back({
			"form_id": wid,
			"editor_id": edid,
			"chance": int(entry.get("chance", 0)),
		})
	return result

## Holds or resumes the weather, for an interior visit: game.gd holds it on
## entering an interior so it does not change while the player is indoors.
## Not the game pause (get_tree().paused), which stops WeatherManager with
## the rest of the game scene.
func set_weather_paused(p: bool) -> void:
	set_process(not p)

## Advance blend transition. Called by game.gd with game-hour delta.
## (Stub: full random weather selection triggered by volatility will be
## added in a follow-up task once the basic rendering path is verified.)
func advance(delta_hours: float) -> void:
	if blend_alpha >= 1.0:
		return
	blend_alpha = minf(1.0, blend_alpha + delta_hours / WEATHER_TRANSITION_HOURS)

## Returns the interpolated sky color for a given type index and time-of-day
## slot pair (slot_a, slot_b) blended by t [0,1] across the day phase,
## then cross-faded between weather_from and weather_to by blend_alpha.
func get_interpolated_color(color_type: int, slot_a: int, slot_b: int, t: float) -> Color:
	var ca := _get_color(weather_from, color_type, slot_a)
	var cb := _get_color(weather_from, color_type, slot_b)
	var from_color := ca.lerp(cb, t)
	if blend_alpha >= 1.0:
		return from_color
	var ca2 := _get_color(weather_to, color_type, slot_a)
	var cb2 := _get_color(weather_to, color_type, slot_b)
	var to_color := ca2.lerp(cb2, t)
	return from_color.lerp(to_color, blend_alpha)

## Raw color lookup from a weather Dictionary at [type][slot].
## The "colors" key is a PackedByteArray of 10 × 6 × 4 RGBA bytes.
func _get_color(weather: Dictionary, type_idx: int, slot_idx: int) -> Color:
	var bytes: PackedByteArray = weather.get("colors", PackedByteArray())
	if bytes.is_empty():
		return Color.BLACK
	var offset := (type_idx * 6 + slot_idx) * 4
	if offset + 3 >= bytes.size():
		return Color.BLACK
	return Color(
		bytes[offset]     / 255.0,
		bytes[offset + 1] / 255.0,
		bytes[offset + 2] / 255.0,
		1.0
	)

## Convenience: fog params interpolated for the current time-of-day fraction
## (0 = full night, 1 = full day). Blended across active weathers.
func get_fog_params(day_frac: float) -> Dictionary:
	var fn_: float = weather_from.get("fog_night_near", 1000.0)
	var ff_: float = weather_from.get("fog_night_far",  200000.0)
	var fd_near: float = weather_from.get("fog_day_near", 1000.0)
	var fd_far:  float = weather_from.get("fog_day_far",  250000.0)
	var near := lerpf(fn_, fd_near, day_frac)
	var far  := lerpf(ff_, fd_far,  day_frac)
	if blend_alpha < 1.0:
		var tn_: float = weather_to.get("fog_night_near", 1000.0)
		var tf_: float = weather_to.get("fog_night_far",  200000.0)
		var td_near: float = weather_to.get("fog_day_near", 1000.0)
		var td_far:  float = weather_to.get("fog_day_far",  250000.0)
		var tnear := lerpf(tn_, td_near, day_frac)
		var tfar  := lerpf(tf_, td_far,  day_frac)
		near = lerpf(near, tnear, blend_alpha)
		far  = lerpf(far,  tfar,  blend_alpha)
	return {"near": near, "far": far}
