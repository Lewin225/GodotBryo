extends Control

## Debug Tools window -> TabContainer -> "Time & Weather" tab.
## Comprehensive inspection and control panel for in-game time, timescale,
## climate, weather presets, crossfading, and celestial/fog parameters.

const REFRESH_INTERVAL_SEC := 0.2

var _game: Node3D = null
var _refresh_timer := 0.0
var _user_scrubbing_time := false
var _user_scrubbing_blend := false

# Time Controls
var _time_display_label: Label
var _time_slider: HSlider
var _hour_spin: SpinBox
var _pause_button: Button
var _timescale_spin: SpinBox

# Weather Controls
var _climate_label: Label
var _weather_status_label: Label
var _weather_option: OptionButton
var _instant_weather_check: CheckBox
var _blend_slider: HSlider
var _blend_label: Label

# Environment Diagnostics
var _sun_status_label: Label
var _peak_energy_spin: SpinBox
var _fog_status_label: Label
var _ambient_swatch: ColorRect
var _ambient_label: Label
var _sun_swatch: ColorRect
var _sun_label: Label
var _sky_swatch: ColorRect
var _sky_label: Label
var _fog_swatch: ColorRect
var _fog_label: Label

func _ready() -> void:
	_game = get_tree().root.get_node_or_null("Game") as Node3D
	_build_ui()
	_populate_weathers()
	_refresh()

func _build_ui() -> void:
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	add_child(scroll)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(margin)

	var root_vbox := VBoxContainer.new()
	root_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_vbox.add_theme_constant_override("separation", 10)
	margin.add_child(root_vbox)

	# ------------------------------------------------------------------------
	# SECTION 1: Time & Calendar
	# ------------------------------------------------------------------------
	_make_section_header(root_vbox, "In-Game Time & Calendar")

	_time_display_label = Label.new()
	_time_display_label.text = "Loading..."
	_time_display_label.add_theme_font_size_override("font_size", 16)
	root_vbox.add_child(_time_display_label)

	# Time scrubber row
	var time_row := HBoxContainer.new()
	time_row.add_theme_constant_override("separation", 8)
	root_vbox.add_child(time_row)

	var time_lbl := Label.new()
	time_lbl.text = "Hour (0-24):"
	time_row.add_child(time_lbl)

	_time_slider = HSlider.new()
	_time_slider.min_value = 0.0
	_time_slider.max_value = 24.0
	_time_slider.step = 0.05
	_time_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_time_slider.drag_started.connect(func(): _user_scrubbing_time = true)
	_time_slider.drag_ended.connect(func(_val):
		_user_scrubbing_time = false
		_on_time_scrubbed(_time_slider.value)
	)
	_time_slider.value_changed.connect(func(v):
		if _user_scrubbing_time:
			_on_time_scrubbed(v)
	)
	time_row.add_child(_time_slider)

	_hour_spin = SpinBox.new()
	_hour_spin.min_value = 0.0
	_hour_spin.max_value = 23.99
	_hour_spin.step = 0.1
	_hour_spin.custom_minimum_size = Vector2(80, 0)
	_hour_spin.value_changed.connect(_on_time_spin_changed)
	time_row.add_child(_hour_spin)

	# Quick Time Jump Presets
	var preset_row := HBoxContainer.new()
	preset_row.add_theme_constant_override("separation", 6)
	root_vbox.add_child(preset_row)

	_make_btn(preset_row, "Dawn (06:00)", func(): _set_hour(6.0))
	_make_btn(preset_row, "Morning (09:00)", func(): _set_hour(9.0))
	_make_btn(preset_row, "Noon (12:00)", func(): _set_hour(12.0))
	_make_btn(preset_row, "Sunset (18:00)", func(): _set_hour(18.0))
	_make_btn(preset_row, "Dusk (20:00)", func(): _set_hour(20.0))
	_make_btn(preset_row, "Midnight (00:00)", func(): _set_hour(0.0))

	# Relative Nudge Row
	var nudge_row := HBoxContainer.new()
	nudge_row.add_theme_constant_override("separation", 6)
	root_vbox.add_child(nudge_row)

	_make_btn(nudge_row, "-1 Hour", func(): _nudge_hours(-1.0))
	_make_btn(nudge_row, "+1 Hour", func(): _nudge_hours(1.0))
	_make_btn(nudge_row, "+6 Hours", func(): _nudge_hours(6.0))
	_make_btn(nudge_row, "+12 Hours", func(): _nudge_hours(12.0))

	# Play / Pause & Timescale Row
	var speed_row := HBoxContainer.new()
	speed_row.add_theme_constant_override("separation", 8)
	root_vbox.add_child(speed_row)

	_pause_button = Button.new()
	_pause_button.text = "Pause Time"
	_pause_button.pressed.connect(_toggle_pause)
	speed_row.add_child(_pause_button)

	var ts_label := Label.new()
	ts_label.text = "TimeScale:"
	speed_row.add_child(ts_label)

	_timescale_spin = SpinBox.new()
	_timescale_spin.min_value = 0.0
	_timescale_spin.max_value = 10000.0
	_timescale_spin.step = 1.0
	_timescale_spin.value = 30.0
	_timescale_spin.custom_minimum_size = Vector2(90, 0)
	_timescale_spin.value_changed.connect(_on_timescale_changed)
	speed_row.add_child(_timescale_spin)

	_make_btn(speed_row, "1x (Realtime)", func(): _set_timescale(1.0))
	_make_btn(speed_row, "30x (Default)", func(): _set_timescale(30.0))
	_make_btn(speed_row, "120x (Fast)", func(): _set_timescale(120.0))
	_make_btn(speed_row, "1800x (Timelapse)", func(): _set_timescale(1800.0))

	# ------------------------------------------------------------------------
	# SECTION 2: Climate & Weather
	# ------------------------------------------------------------------------
	_make_separator(root_vbox)
	_make_section_header(root_vbox, "Climate & Weather Control")

	_climate_label = Label.new()
	_climate_label.text = "Climate: None"
	root_vbox.add_child(_climate_label)

	_weather_status_label = Label.new()
	_weather_status_label.text = "Active Weather: None"
	root_vbox.add_child(_weather_status_label)

	# Weather selection row
	var wthr_row := HBoxContainer.new()
	wthr_row.add_theme_constant_override("separation", 8)
	root_vbox.add_child(wthr_row)

	var sel_lbl := Label.new()
	sel_lbl.text = "Set Weather:"
	wthr_row.add_child(sel_lbl)

	_weather_option = OptionButton.new()
	_weather_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_weather_option.item_selected.connect(_on_weather_selected)
	wthr_row.add_child(_weather_option)

	_instant_weather_check = CheckBox.new()
	_instant_weather_check.text = "Instant"
	_instant_weather_check.button_pressed = true
	_instant_weather_check.tooltip_text = "If checked, weather applies instantly. If unchecked, crossfades smoothly over 2 in-game hours."
	wthr_row.add_child(_instant_weather_check)

	# Manual blend alpha scrubber
	var blend_row := HBoxContainer.new()
	blend_row.add_theme_constant_override("separation", 8)
	root_vbox.add_child(blend_row)

	_blend_label = Label.new()
	_blend_label.text = "Crossfade Blend: 100%"
	blend_row.add_child(_blend_label)

	_blend_slider = HSlider.new()
	_blend_slider.min_value = 0.0
	_blend_slider.max_value = 1.0
	_blend_slider.step = 0.01
	_blend_slider.value = 1.0
	_blend_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_blend_slider.drag_started.connect(func(): _user_scrubbing_blend = true)
	_blend_slider.drag_ended.connect(func(_val):
		_user_scrubbing_blend = false
		_on_blend_scrubbed(_blend_slider.value)
	)
	_blend_slider.value_changed.connect(func(v):
		if _user_scrubbing_blend:
			_on_blend_scrubbed(v)
	)
	blend_row.add_child(_blend_slider)

	# ------------------------------------------------------------------------
	# SECTION 3: Sun, Fog & Color Diagnostics
	# ------------------------------------------------------------------------
	_make_separator(root_vbox)
	_make_section_header(root_vbox, "Environment & Lighting Diagnostics")

	_sun_status_label = Label.new()
	root_vbox.add_child(_sun_status_label)

	var sun_cfg_row := HBoxContainer.new()
	sun_cfg_row.add_theme_constant_override("separation", 8)
	root_vbox.add_child(sun_cfg_row)

	var pse_lbl := Label.new()
	pse_lbl.text = "Peak Sun Energy:"
	sun_cfg_row.add_child(pse_lbl)

	_peak_energy_spin = SpinBox.new()
	_peak_energy_spin.min_value = 0.1
	_peak_energy_spin.max_value = 20.0
	_peak_energy_spin.step = 0.1
	_peak_energy_spin.value = 3.0
	_peak_energy_spin.custom_minimum_size = Vector2(80, 0)
	_peak_energy_spin.value_changed.connect(_on_peak_energy_changed)
	sun_cfg_row.add_child(_peak_energy_spin)

	_fog_status_label = Label.new()
	root_vbox.add_child(_fog_status_label)

	# Swatches grid
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 8)
	root_vbox.add_child(grid)

	var amb_pair := _make_swatch_row("Ambient Light:")
	_ambient_swatch = amb_pair[0]
	_ambient_label  = amb_pair[1]
	grid.add_child(amb_pair[2])

	var sun_pair := _make_swatch_row("Sun Directional:")
	_sun_swatch = sun_pair[0]
	_sun_label  = sun_pair[1]
	grid.add_child(sun_pair[2])

	var sky_pair := _make_swatch_row("Sky Top:")
	_sky_swatch = sky_pair[0]
	_sky_label  = sky_pair[1]
	grid.add_child(sky_pair[2])

	var fog_pair := _make_swatch_row("Horizon / Fog:")
	_fog_swatch = fog_pair[0]
	_fog_label  = fog_pair[1]
	grid.add_child(fog_pair[2])

func _make_section_header(parent: Control, title: String) -> void:
	var l := Label.new()
	l.text = title
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", Color(1.0, 0.85, 0.45))
	parent.add_child(l)

func _make_separator(parent: Control) -> void:
	var sep := HSeparator.new()
	parent.add_child(sep)

func _make_btn(parent: Control, text: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.pressed.connect(callback)
	parent.add_child(btn)
	return btn

func _make_swatch_row(title: String) -> Array:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)

	var swatch := ColorRect.new()
	swatch.custom_minimum_size = Vector2(24, 24)
	swatch.color = Color.BLACK
	hbox.add_child(swatch)

	var lbl := Label.new()
	lbl.text = title
	hbox.add_child(lbl)

	return [swatch, lbl, hbox]

func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_refresh_timer += delta
	if _refresh_timer < REFRESH_INTERVAL_SEC:
		return
	_refresh_timer = 0.0
	_refresh()

func _refresh() -> void:
	if _game == null:
		_time_display_label.text = "(Game root not found)"
		return

	var gtm: GameTimeManager = _game.get("game_time_manager")
	var wm: WeatherManager   = _game.get("weather_manager")
	var cc: CelestialController = _game.get("celestial_controller")

	# 1. Update Time Display
	if gtm != null:
		var paused_str := " [PAUSED]" if gtm.is_paused else ""
		_time_display_label.text = "%s   |   %s%s" % [
			gtm.get_formatted_datetime(),
			"Day %d (DaysPassed: %.2f)" % [gtm.game_day, gtm.game_days_passed],
			paused_str
		]
		_pause_button.text = "Resume Time" if gtm.is_paused else "Pause Time"

		if not _user_scrubbing_time:
			_time_slider.set_value_no_signal(gtm.game_hour)
			_hour_spin.set_value_no_signal(gtm.game_hour)

		_timescale_spin.set_value_no_signal(gtm.timescale)
	else:
		_time_display_label.text = "GameTimeManager: not attached"

	# 2. Update Climate & Weather
	if wm != null:
		var climate: Dictionary = wm.climate
		if climate.is_empty():
			_climate_label.text = "Climate: None (Player is in an Interior or no Worldspace loaded)"
		else:
			_climate_label.text = "Climate: %s (0x%X) | Sunrise: %.1fh–%.1fh | Sunset: %.1fh–%.1fh" % [
				climate.get("editor_id", "?"),
				int(climate.get("form_id", 0)),
				climate.get("sunrise_begin", 6.0),
				climate.get("sunrise_end", 8.0),
				climate.get("sunset_begin", 18.0),
				climate.get("sunset_end", 20.0)
			]

		var wf: Dictionary = wm.weather_from
		var wt: Dictionary = wm.weather_to
		if wf.is_empty():
			_weather_status_label.text = "Active Weather: None"
		elif wf == wt or wm.blend_alpha >= 1.0:
			_weather_status_label.text = "Active Weather: %s (0x%X)" % [
				wt.get("editor_id", "?"), int(wt.get("form_id", 0))
			]
		else:
			_weather_status_label.text = "Active Weather: %s → %s (Transitioning)" % [
				wf.get("editor_id", "?"), wt.get("editor_id", "?")
			]

		if not _user_scrubbing_blend:
			_blend_slider.set_value_no_signal(wm.blend_alpha)
		_blend_label.text = "Crossfade Blend: %d%%" % [int(wm.blend_alpha * 100.0)]

		# Update weather option selection if not focused
		if not _weather_option.has_focus() and not wt.is_empty():
			var cur_fid := int(wt.get("form_id", 0))
			for i in range(_weather_option.item_count):
				if _weather_option.get_item_id(i) == cur_fid:
					_weather_option.selected = i
					break

	var hour: float = gtm.game_hour if gtm != null else 12.0
	var sun: DirectionalLight3D = _game.get("_sun")
	if sun != null:
		var climate: Dictionary = wm.climate if wm != null else {}
		var rb: float = climate.get("sunrise_begin", 6.0)
		var se: float = climate.get("sunset_end", 20.0)
		var is_daytime := (hour >= rb and hour <= se)
		var source_name := "Sun (Day)" if is_daytime else "Moon (Night)"
		_sun_status_label.text = "Directional Light: %s | Energy: %.2f | AngleX: %.1f°" % [
			source_name, sun.light_energy, sun.rotation_degrees.x
		]
	else:
		_sun_status_label.text = "Directional Light: Not found"

	if cc != null and not _peak_energy_spin.has_focus():
		_peak_energy_spin.set_value_no_signal(cc.peak_sun_energy)

	if wm != null:
		var climate: Dictionary = wm.climate
		var rb: float = climate.get("sunrise_begin", 6.0)
		var re: float = climate.get("sunrise_end", 8.0)
		var sb: float = climate.get("sunset_begin", 18.0)
		var se: float = climate.get("sunset_end", 20.0)
		var day_frac: float
		if hour < rb: day_frac = 0.0
		elif hour < re: day_frac = (hour - rb) / max(re - rb, 0.001)
		elif hour < sb: day_frac = 1.0
		elif hour < se: day_frac = 1.0 - (hour - sb) / max(se - sb, 0.001)
		else: day_frac = 0.0

		var fog := wm.get_fog_params(day_frac)
		_fog_status_label.text = "Fog Distance: Near=%.0fm  Far=%.0fm (day fraction: %.2f)" % [
			float(fog.get("near", 1000.0)) / 70.0,
			float(fog.get("far", 250000.0)) / 70.0,
			day_frac
		]

		# Colors
		var slot := WeatherManager.SLOT_NIGHT
		if hour >= rb and hour < re: slot = WeatherManager.SLOT_SUNRISE
		elif hour >= re and hour < sb: slot = WeatherManager.SLOT_DAY
		elif hour >= sb and hour < se: slot = WeatherManager.SLOT_SUNSET

		var amb_col := wm.get_interpolated_color(WeatherManager.COL_AMBIENT, slot, slot, 0.0)
		var sun_col := wm.get_interpolated_color(WeatherManager.COL_SUN_LIGHT, slot, slot, 0.0)
		var sky_col := wm.get_interpolated_color(WeatherManager.COL_SKY_UPPER, slot, slot, 0.0)
		var fog_col := wm.get_interpolated_color(WeatherManager.COL_FOG, slot, slot, 0.0)

		_update_swatch(_ambient_swatch, _ambient_label, "Ambient Light", amb_col)
		_update_swatch(_sun_swatch, _sun_label, "Sun Light", sun_col)
		_update_swatch(_sky_swatch, _sky_label, "Sky Top", sky_col)
		_update_swatch(_fog_swatch, _fog_label, "Horizon Fog", fog_col)

func _update_swatch(rect: ColorRect, lbl: Label, title: String, col: Color) -> void:
	rect.color = col
	lbl.text = "%s: rgb(%d, %d, %d)" % [
		title, int(col.r * 255), int(col.g * 255), int(col.b * 255)
	]

# ----------------------------------------------------------------------------
# Callbacks & Mutators
# ----------------------------------------------------------------------------

func _set_hour(hour: float) -> void:
	if _game == null: return
	var gtm: GameTimeManager = _game.get("game_time_manager")
	if gtm != null:
		gtm.set_hour(hour)
		_refresh()

func _nudge_hours(delta_h: float) -> void:
	if _game == null: return
	var gtm: GameTimeManager = _game.get("game_time_manager")
	if gtm != null:
		gtm.advance_hours(delta_h)
		_refresh()

func _on_time_scrubbed(val: float) -> void:
	_set_hour(val)

func _on_time_spin_changed(val: float) -> void:
	_set_hour(val)

func _toggle_pause() -> void:
	if _game == null: return
	var gtm: GameTimeManager = _game.get("game_time_manager")
	if gtm != null:
		gtm.is_paused = not gtm.is_paused
		_refresh()

func _set_timescale(ts: float) -> void:
	if _game == null: return
	var gtm: GameTimeManager = _game.get("game_time_manager")
	if gtm != null:
		gtm.timescale = ts
		_timescale_spin.set_value_no_signal(ts)
		_refresh()

func _on_timescale_changed(val: float) -> void:
	_set_timescale(val)

func _populate_weathers() -> void:
	_weather_option.clear()
	if _game == null:
		return
	var wm: WeatherManager = _game.get("weather_manager")
	if wm == null:
		return
	var list := wm.get_climate_weather_list()
	for entry in list:
		var name_str := "%s (0x%X - %d%%)" % [entry["editor_id"], entry["form_id"], entry["chance"]]
		_weather_option.add_item(name_str, entry["form_id"])

	# Also add standard NV fallback weathers if available
	var standard_weathers := [
		{ "form_id": 0x176574, "name": "NVWastelandClearNight" },
		{ "form_id": 0x0ffc88, "name": "NVWastelandClear" },
		{ "form_id": 0x173564, "name": "NVUrbanClear" },
		{ "form_id": 0x00015e, "name": "DefaultWeather" },
		{ "form_id": 0x064609, "name": "WastelandClear" },
	]
	for sw in standard_weathers:
		var found := false
		for i in range(_weather_option.item_count):
			if _weather_option.get_item_id(i) == sw["form_id"]:
				found = true
				break
		if not found:
			_weather_option.add_item("%s (0x%X)" % [sw["name"], sw["form_id"]], sw["form_id"])

func _on_weather_selected(index: int) -> void:
	var fid := _weather_option.get_item_id(index)
	if fid == 0 or _game == null:
		return
	var wm: WeatherManager = _game.get("weather_manager")
	if wm != null:
		var instant := _instant_weather_check.button_pressed
		wm.set_weather(fid, instant)
		_refresh()

func _on_blend_scrubbed(val: float) -> void:
	if _game == null: return
	var wm: WeatherManager = _game.get("weather_manager")
	if wm != null:
		wm.blend_alpha = clampf(val, 0.0, 1.0)
		_refresh()

func _on_peak_energy_changed(val: float) -> void:
	if _game == null: return
	var cc: CelestialController = _game.get("celestial_controller")
	if cc != null:
		cc.peak_sun_energy = val
		_refresh()

