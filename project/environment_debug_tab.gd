extends Control

## Debug Tools window (game.tscn) -> TabContainer -> "Envrioment" tab.
## Read-only. UI is scene-authored (game.tscn, under this node) same as
## world_streaming_debug_tab.gd's own established pattern -- this script
## only wires already-placed nodes up to real data and refreshes them.
##
## Shows the currently loaded cell's real CELL.XCLL data (per-cell authored
## ambient/directional/fog lighting -- game.gd's _apply_cell_lighting()) side
## by side with whatever's actually applied on the live WorldEnvironment
## right now, so a lighting mismatch (or a cell with no XCLL at all, a real
## valid case -- exterior cells, or an interior cell whose designer never
## touched the lighting tab) is visible at a glance instead of having to
## dig through interior_environment.tres and the ESM by hand.
const REFRESH_INTERVAL_SEC := 0.25

@onready var _cell_label: RichTextLabel = $Margin/VBox/CellLabel
@onready var _xcll_label: RichTextLabel = $Margin/VBox/XcllLabel
@onready var _applied_label: RichTextLabel = $Margin/VBox/AppliedLabel

var _game: Node3D
var _refresh_timer := 0.0

func _ready() -> void:
	_game = get_tree().root.get_node("Game")
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
		_xcll_label.text = ""
		_applied_label.text = ""
		return

	var editor_id: String = esm.get_cell_editor_id(cell_form_id)
	var wrld_form_id: int = esm.get_cell_worldspace(cell_form_id)
	var is_interior := wrld_form_id == -1
	_cell_label.text = "%s (0x%X)\n%s" % [
		editor_id if editor_id != "" else "(unnamed)", cell_form_id,
		"interior" if is_interior else "exterior (worldspace 0x%X)" % wrld_form_id,
	]

	var lighting: Dictionary = esm.get_cell_lighting_data(cell_form_id)
	if lighting.is_empty():
		_xcll_label.text = "(no XCLL subrecord on this cell -- %s)" % (
				"expected, exterior cells inherit worldspace lighting instead" if not is_interior
				else "a real, valid case -- this cell's designer never touched the lighting tab")
	else:
		var ambient: Color = lighting["ambient_color"]
		var directional: Color = lighting["directional_color"]
		_xcll_label.text = "\n".join([
			"ambient:     %s" % _color_str(ambient),
			"directional: %s" % _color_str(directional),
			"fog near/far: %.1f / %.1f   power: %.2f   clip: %.1f" % [
				lighting["fog_near"], lighting["fog_far"], lighting["fog_power"], lighting["fog_clip_distance"]],
			"directional fade: %.2f" % lighting["directional_fade"],
		])

	var world_env: WorldEnvironment = _game._world_environment
	var env: Environment = world_env.environment if world_env != null else null
	if env == null:
		_applied_label.text = "(no Environment assigned to WorldEnvironment)"
		return
	_applied_label.text = "\n".join([
		"ambient_light_color:  %s" % _color_str(env.ambient_light_color),
		"ambient_light_energy: %.2f   source: %d" % [env.ambient_light_energy, env.ambient_light_source],
		"sdfgi_enabled: %s   sdfgi_energy: %.2f" % [env.sdfgi_enabled, env.sdfgi_energy],
		"tonemap_mode: %d   tonemap_exposure: %.2f" % [env.tonemap_mode, env.tonemap_exposure],
		"background_mode: %d   background_color: %s" % [env.background_mode, _color_str(env.background_color)],
	])

func _color_str(c: Color) -> String:
	return "rgb(%.0f, %.0f, %.0f)  [%.3f, %.3f, %.3f]" % [c.r * 255.0, c.g * 255.0, c.b * 255.0, c.r, c.g, c.b]
