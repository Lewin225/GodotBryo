class_name CelestialController
extends Node

## Drives the sun/moon DirectionalLight3D, sky ambient color, procedural sky,
## and fog based on the current in-game hour and active CLMT/WTHR ESM data.
##
## Gamebryo Fidelity:
## 1. Directional Light:
##    - During daytime [sunrise_begin, sunset_end], the directional light tracks
##      the Sun from East to West with an elevation arc (tilted southward).
##    - The light brightness dynamically scales with the sine of the elevation
##      angle (sin(theta)), peaking at solar noon.
##    - During nighttime, the directional light tracks the Moon across the sky,
##      casting moonlight with the WTHR.NAM0[SunLight] Night slot color and
##      scaled by moon elevation sin(theta_moon).
## 2. Color Interpolation:
##    - 4-point continuous piecewise interpolation across the 24h cycle:
##      Sunrise window [sunrise_begin, sunrise_end]: Night -> Sunrise -> Day
##      Day [sunrise_end, sunset_begin]: Day
##      Sunset window [sunset_begin, sunset_end]: Day -> Sunset -> Night
##      Night [sunset_end, sunrise_begin+24h]: Night
## 3. Light and Environment:
##    - Directional light color comes from WTHR.NAM0[SunLight].
##    - Ambient light color comes from WTHR.NAM0[Ambient].
##    - Sky & horizon colors come from WTHR.NAM0[SkyUpper], [Horizon], [Fog].

# Latitude inclination of celestial arc (degrees south tilt in northern hemisphere).
const LATITUDE_TILT_DEG := 30.0
## Fixed roll around the light's local forward axis. This changes the
## directional shadow-map texel alignment without changing the sun's actual
## casting direction, avoiding the worst-case grid-aligned aliasing pattern.
const SHADOW_MAP_ROLL_DEG := 22.5
## Sun elevation at which the ground hemisphere reaches full daylight strength.
## This is deliberately an elevation threshold rather than an arbitrary clock
## time so it follows the same celestial curve as the directional light.
const GROUND_TWILIGHT_ELEVATION := 0.15
## Keep a small authored ground contribution for moon/starlight at night, but
## prevent the sky ground hemisphere from lighting distant terrain as daylight.
const NIGHT_GROUND_LIGHT := 0.04
## Preserve a small amount of distant atmospheric color at night without
## allowing a daylight-tuned depth-fog tint to glow across the landscape.
const NIGHT_FOG_LIGHT := 0.08

var peak_sun_energy: float = 3.0
var peak_moon_energy: float = 0.2
var min_sun_energy: float = 0.05

var _sun: DirectionalLight3D = null
var _world_environment: WorldEnvironment = null
var _exterior_env: Environment = null   # mutable duplicate of EXTERIOR_ENVIRONMENT
var _weather: WeatherManager = null
var _is_exterior: bool = false
var _base_fog_light_color := Color.WHITE

func configure(
		sun: DirectionalLight3D,
		world_env: WorldEnvironment,
		base_exterior_env: Environment,
		weather: WeatherManager) -> void:
	_sun = sun
	_world_environment = world_env
	_exterior_env = base_exterior_env.duplicate() as Environment
	_weather = weather
	_base_fog_light_color = _exterior_env.fog_light_color

## Called by game.gd each frame (exterior only).
func update(game_hour: float, climate: Dictionary) -> void:
	if not _is_exterior or _sun == null or _exterior_env == null:
		return

	var rb: float = climate.get("sunrise_begin", 6.0)
	var re: float = climate.get("sunrise_end",   8.0)
	var sb: float = climate.get("sunset_begin",  18.0)
	var se: float = climate.get("sunset_end",    20.0)

	# 4-point continuous time-of-day phase slots
	var m_rise := (rb + re) * 0.5
	var m_set  := (sb + se) * 0.5

	var slot_a: int
	var slot_b: int
	var phase_t: float

	if game_hour >= rb and game_hour < m_rise:
		# Early sunrise: Night -> Sunrise
		slot_a = WeatherManager.SLOT_NIGHT
		slot_b = WeatherManager.SLOT_SUNRISE
		phase_t = (game_hour - rb) / maxf(m_rise - rb, 0.001)
	elif game_hour >= m_rise and game_hour < re:
		# Late sunrise: Sunrise -> Day
		slot_a = WeatherManager.SLOT_SUNRISE
		slot_b = WeatherManager.SLOT_DAY
		phase_t = (game_hour - m_rise) / maxf(re - m_rise, 0.001)
	elif game_hour >= re and game_hour < sb:
		# Full day
		slot_a = WeatherManager.SLOT_DAY
		slot_b = WeatherManager.SLOT_DAY
		phase_t = 0.0
	elif game_hour >= sb and game_hour < m_set:
		# Early sunset: Day -> Sunset
		slot_a = WeatherManager.SLOT_DAY
		slot_b = WeatherManager.SLOT_SUNSET
		phase_t = (game_hour - sb) / maxf(m_set - sb, 0.001)
	elif game_hour >= m_set and game_hour < se:
		# Late sunset: Sunset -> Night
		slot_a = WeatherManager.SLOT_SUNSET
		slot_b = WeatherManager.SLOT_NIGHT
		phase_t = (game_hour - m_set) / maxf(se - m_set, 0.001)
	else:
		# Night
		slot_a = WeatherManager.SLOT_NIGHT
		slot_b = WeatherManager.SLOT_NIGHT
		phase_t = 0.0

	var sun_elevation := _sun_elevation(game_hour, rb, se)
	_apply_celestial_light(game_hour, rb, se, slot_a, slot_b, phase_t)
	_apply_colors(slot_a, slot_b, phase_t, _ground_light_strength(sun_elevation))
	_apply_fog(game_hour, rb, re, sb, se)

## Set whether the exterior renderer should be active.
func set_exterior(is_exterior: bool) -> void:
	_is_exterior = is_exterior
	if is_exterior and _world_environment != null and _exterior_env != null:
		_world_environment.environment = _exterior_env

## Computes 3D celestial vector and scales DirectionalLight3D brightness with sin(theta).
func _apply_celestial_light(
		hour: float,
		sunrise_begin: float,
		sunset_end: float,
		slot_a: int,
		slot_b: int,
		phase_t: float) -> void:
	if _sun == null or _weather == null:
		return

	var tilt_rad := deg_to_rad(LATITUDE_TILT_DEG)
	var is_daytime := (hour >= sunrise_begin and hour <= sunset_end)
	var celestial_dir: Vector3
	var sin_elevation: float
	var light_col: Color
	var light_energy: float

	if is_daytime:
		var day_span := maxf(sunset_end - sunrise_begin, 0.001)
		var day_u := (hour - sunrise_begin) / day_span  # [0, 1] from sunrise to sunset
		var phi := day_u * PI  # 0 at sunrise (East), PI/2 at noon, PI at sunset (West)
		sin_elevation = _sun_elevation(hour, sunrise_begin, sunset_end)

		# 3D Celestial position vector:
		# X: -cos(phi) -> East (-1) to West (+1)
		# Y: sin(phi) * cos(tilt) -> Up
		# Z: sin(phi) * sin(tilt) -> South
		celestial_dir = Vector3(
			-cos(phi),
			sin_elevation * cos(tilt_rad),
			sin_elevation * sin(tilt_rad)
		).normalized()

		# Light color from NAM0[SunLight]
		light_col = _godot_color(_weather.get_interpolated_color(
			WeatherManager.COL_SUN_LIGHT, slot_a, slot_b, phase_t))

		# Gamebryo parity: brightness dynamically scales with sin(theta)
		light_energy = lerpf(min_sun_energy, peak_sun_energy, sin_elevation)
	else:
		# Nighttime: directional light tracks the Moon
		var day_span := sunset_end - sunrise_begin
		var night_span := maxf(24.0 - day_span, 0.001)
		var h_rel := fposmod(hour - sunset_end, 24.0)
		var night_u := h_rel / night_span  # [0, 1] from sunset to sunrise
		var phi_moon := night_u * PI
		sin_elevation = maxf(0.0, sin(phi_moon))

		celestial_dir = Vector3(
			-cos(phi_moon),
			sin_elevation * cos(tilt_rad),
			sin_elevation * sin(tilt_rad)
		).normalized()

		# Moon light color from NAM0[SunLight] Night slot
		light_col = _godot_color(_weather.get_interpolated_color(
			WeatherManager.COL_SUN_LIGHT, WeatherManager.SLOT_NIGHT, WeatherManager.SLOT_NIGHT, 0.0))

		# Moonlight brightness scales with moon elevation
		light_energy = peak_moon_energy * sin_elevation

	# Orient DirectionalLight3D so rays shine from celestial position toward scene
	var ray_dir := -celestial_dir
	_sun.global_transform = Transform3D().looking_at(ray_dir, Vector3.UP)
	_sun.rotate_object_local(Vector3.FORWARD, deg_to_rad(SHADOW_MAP_ROLL_DEG))
	_sun.light_color = light_col
	_sun.light_energy = light_energy
	_sun.visible = (light_energy > 0.005)

## Apply ambient and sky colors from the WeatherManager's NAM0 table.
func _apply_colors(slot_a: int, slot_b: int, phase_t: float, ground_strength: float) -> void:
	if _weather == null or _exterior_env == null:
		return

	# WTHR.NAM0 stores the authored Gamebryo colour values in linear-light
	# space. WeatherManager deliberately interpolates those values in that
	# space. Godot's colour properties are sRGB-facing (the same boundary used
	# by the XEMI/XREF tint path), so encode only when handing them to the
	# renderer. Converting the raw samples before interpolation would make the
	# time-of-day blend itself gamma-biased.
	var ambient_col: Color = _godot_color(_weather.get_interpolated_color(
		WeatherManager.COL_AMBIENT, slot_a, slot_b, phase_t))
	var sky_upper: Color = _godot_color(_weather.get_interpolated_color(
		WeatherManager.COL_SKY_UPPER, slot_a, slot_b, phase_t))
	var sky_lower: Color = _weather.get_interpolated_color(
		WeatherManager.COL_SKY_LOWER, slot_a, slot_b, phase_t)
	var horizon_col: Color = _godot_color(_weather.get_interpolated_color(
		WeatherManager.COL_HORIZON, slot_a, slot_b, phase_t))
	var fog_linear: Color = _weather.get_interpolated_color(
		WeatherManager.COL_FOG, slot_a, slot_b, phase_t)
	var ground_bottom_col: Color = _godot_color(sky_lower * ground_strength)
	var ground_horizon_col: Color = _godot_color(fog_linear * ground_strength)

	_exterior_env.ambient_light_color = ambient_col
	_exterior_env.ambient_light_energy = 1.0

	var sky := _exterior_env.sky
	if sky != null:
		var mat := sky.sky_material
		if mat is ProceduralSkyMaterial:
			mat.sky_top_color = sky_upper
			mat.sky_horizon_color = horizon_col
			mat.ground_bottom_color = ground_bottom_col
			mat.ground_horizon_color = ground_horizon_col
			mat.sun_angle_max = 30.0

## The same normalized solar elevation used by the directional-light path.
## Returning zero outside the daylight arc keeps the ground contribution
## independent of the upper sky's authored night colors.
static func _sun_elevation(hour: float, sunrise_begin: float, sunset_end: float) -> float:
	if hour < sunrise_begin or hour > sunset_end:
		return 0.0
	var day_span := maxf(sunset_end - sunrise_begin, 0.001)
	var day_u := (hour - sunrise_begin) / day_span
	return maxf(0.0, sin(day_u * PI))

static func _ground_light_strength(sun_elevation: float) -> float:
	var daylight := smoothstep(0.0, GROUND_TWILIGHT_ELEVATION, sun_elevation)
	return lerpf(NIGHT_GROUND_LIGHT, 1.0, daylight)

## Convert an authored Gamebryo-linear colour to the sRGB-facing Godot
## property/uniform representation. Alpha is not colour-managed by Godot.
static func _godot_color(authored_linear: Color) -> Color:
	return authored_linear.linear_to_srgb()

## Apply fog distance from WeatherManager based on time of day.
func _apply_fog(hour: float, rb: float, re: float, sb: float, se: float) -> void:
	if _exterior_env == null or _weather == null:
		return
	var day_frac: float
	if hour < rb:
		day_frac = 0.0
	elif hour < re:
		day_frac = (hour - rb) / maxf(re - rb, 0.001)
	elif hour < sb:
		day_frac = 1.0
	elif hour < se:
		day_frac = 1.0 - (hour - sb) / maxf(se - sb, 0.001)
	else:
		day_frac = 0.0

	var fog := _weather.get_fog_params(day_frac)
	const GU_TO_M := 1.0 / 70.0
	var fog_near_m: float = float(fog.get("near", 1000.0)) * GU_TO_M
	var fog_far_m: float = float(fog.get("far", 250000.0)) * GU_TO_M
	_exterior_env.fog_depth_begin = fog_near_m
	_exterior_env.fog_depth_end = maxf(fog_far_m, fog_near_m + 1.0)
	if hour < rb and hour > sb:
		_exterior_env.fog_sky_affect = 0
	else:
		_exterior_env.fog_sky_affect = 0.2 + (1-day_frac)
	var fog_strength := lerpf(NIGHT_FOG_LIGHT, 1.0, day_frac)
	_exterior_env.fog_light_color = _base_fog_light_color * fog_strength
	#_exterior_env.volumetric_fog_enabled = true
	_exterior_env.volumetric_fog_density = lerpf(0.01, 0.0002, day_frac)
