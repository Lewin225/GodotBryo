extends Control

## Debug Tools window (game.tscn) -> TabContainer -> "Envrioment" tab.
## Structured side-by-side comparison between real authored CELL.XCLL data
## and live applied WorldEnvironment settings, featuring visual color swatches.

const REFRESH_INTERVAL_SEC := 0.25

@onready var _cell_label: RichTextLabel = $Margin/VBox/CellLabel

@onready var _ambient_swatch: ColorRect = $Margin/VBox/ColumnsContainer/LeftPanel/AmbientRow/AmbientSwatch
@onready var _ambient_label: Label = $Margin/VBox/ColumnsContainer/LeftPanel/AmbientRow/AmbientLabel

@onready var _directional_swatch: ColorRect = $Margin/VBox/ColumnsContainer/LeftPanel/DirectionalRow/DirectionalSwatch
@onready var _directional_label: Label = $Margin/VBox/ColumnsContainer/LeftPanel/DirectionalRow/DirectionalLabel

@onready var _fog_label: Label = $Margin/VBox/ColumnsContainer/LeftPanel/FogLabel
@onready var _fade_label: Label = $Margin/VBox/ColumnsContainer/LeftPanel/FadeLabel
@onready var _xcll_note_label: Label = $Margin/VBox/ColumnsContainer/LeftPanel/XcllNoteLabel

@onready var _env_ambient_swatch: ColorRect = $Margin/VBox/ColumnsContainer/RightPanel/EnvAmbientRow/EnvAmbientSwatch
@onready var _env_ambient_label: Label = $Margin/VBox/ColumnsContainer/RightPanel/EnvAmbientRow/EnvAmbientLabel

@onready var _env_bg_swatch: ColorRect = $Margin/VBox/ColumnsContainer/RightPanel/EnvBgRow/EnvBgSwatch
@onready var _env_bg_label: Label = $Margin/VBox/ColumnsContainer/RightPanel/EnvBgRow/EnvBgLabel

@onready var _env_energy_label: Label = $Margin/VBox/ColumnsContainer/RightPanel/EnvEnergyLabel
@onready var _env_settings_label: Label = $Margin/VBox/ColumnsContainer/RightPanel/EnvSettingsLabel

var _game: Node3D
var _refresh_timer := 0.0


func _ready() -> void:
	_game = get_tree().root.get_node_or_null("Game")
	_refresh()


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		_refresh_timer = REFRESH_INTERVAL_SEC
		_refresh()


func _refresh() -> void:
	if _game == null or _game.cell_loader == null or _game.cell_loader.esm == null:
		_cell_label.text = "(Game/CellLoader not found)"
		return
	var esm: EsmReader = _game.cell_loader.esm
	var cell_form_id: int = _game._hud_cell_form_id
	if cell_form_id == 0:
		_cell_label.text = "(no cell loaded yet)"
		_clear_xcll()
		_clear_applied()
		return

	var editor_id: String = esm.get_cell_editor_id(cell_form_id)
	var wrld_form_id: int = esm.get_cell_worldspace(cell_form_id)
	var is_interior := wrld_form_id == -1
	_cell_label.text = "%s (0x%X)  —  %s" % [
		editor_id if editor_id != "" else "(unnamed)", cell_form_id,
		"Interior Cell" if is_interior else "Exterior Cell (Worldspace 0x%X)" % wrld_form_id,
	]

	var lighting: Dictionary = esm.get_cell_lighting_data(cell_form_id)
	if lighting.is_empty():
		_ambient_swatch.color = Color.BLACK
		_ambient_label.text = "ambient: (none)"
		_directional_swatch.color = Color.BLACK
		_directional_label.text = "directional: (none)"
		_fog_label.text = "fog: (none)"
		_fade_label.text = "directional fade: (none)"
		_xcll_note_label.text = "(No XCLL on this cell — %s)" % (
			"exterior cells inherit worldspace sky lighting" if not is_interior
			else "this interior cell has default lighting")
	else:
		var ambient: Color = lighting["ambient_color"]
		var directional: Color = lighting["directional_color"]
		_ambient_swatch.color = ambient
		_ambient_label.text = "ambient: %s" % _color_str(ambient)
		_directional_swatch.color = directional
		_directional_label.text = "directional: %s" % _color_str(directional)
		_fog_label.text = "fog: near %.1f, far %.1f, pwr %.2f, clip %.1f" % [
			lighting["fog_near"], lighting["fog_far"], lighting["fog_power"], lighting["fog_clip_distance"]
		]
		_fade_label.text = "directional fade: %.2f" % lighting["directional_fade"]
		_xcll_note_label.text = ""

	var world_env: WorldEnvironment = _game._world_environment
	var env: Environment = world_env.environment if world_env != null else null
	if env == null:
		_clear_applied()
		return

	_env_ambient_swatch.color = env.ambient_light_color
	_env_ambient_label.text = "ambient light: %s" % _color_str(env.ambient_light_color)

	_env_bg_swatch.color = env.background_color
	_env_bg_label.text = "background: %s" % _color_str(env.background_color)

	_env_energy_label.text = "energy: %.2f (source: %d)" % [env.ambient_light_energy, env.ambient_light_source]
	_env_settings_label.text = "tonemap: mode %d, exp %.2f | sdfgi: %s (%.2f)" % [
		env.tonemap_mode, env.tonemap_exposure, env.sdfgi_enabled, env.sdfgi_energy
	]


func _clear_xcll() -> void:
	_ambient_swatch.color = Color.BLACK
	_ambient_label.text = "ambient: —"
	_directional_swatch.color = Color.BLACK
	_directional_label.text = "directional: —"
	_fog_label.text = "fog: —"
	_fade_label.text = "directional fade: —"
	_xcll_note_label.text = ""


func _clear_applied() -> void:
	_env_ambient_swatch.color = Color.BLACK
	_env_ambient_label.text = "ambient light: —"
	_env_bg_swatch.color = Color.BLACK
	_env_bg_label.text = "background: —"
	_env_energy_label.text = "energy / source: —"
	_env_settings_label.text = "sdfgi / tonemap: —"


func _color_str(c: Color) -> String:
	return "#%02X%02X%02X  rgb(%d, %d, %d)" % [
		int(c.r * 255.0), int(c.g * 255.0), int(c.b * 255.0),
		int(c.r * 255.0), int(c.g * 255.0), int(c.b * 255.0)
	]
