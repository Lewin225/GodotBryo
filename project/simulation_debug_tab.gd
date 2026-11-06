extends Control

## Debug Tools window (game.tscn) -> TabContainer -> "Simulation" tab: a map
## of NpcSimulationServer's actors in the player's space (SimulationMapView),
## their counts by state, and the low-level travel speed. Overlay also shows
## the map without its background in the screen's top-right corner, over the
## game, while the window is closed.

const REFRESH_SECONDS := 0.2
## LowLevelTravel.speed_scale choices, in the Speed list's order.
const SPEEDS := [1.0, 2.0, 5.0, 10.0, 50.0]
## The corner overlay's size and its gap from the screen edges, pixels.
const OVERLAY_SIZE := Vector2(420, 420)
const OVERLAY_MARGIN := 16.0

@onready var _speed: OptionButton = $Margin/VBox/Controls/Speed
@onready var _show_disabled: CheckBox = $Margin/VBox/Controls/ShowDisabled
@onready var _overlay_toggle: CheckBox = $Margin/VBox/Controls/Overlay
@onready var _stats: Label = $Margin/VBox/Stats
@onready var _map: SimulationMapView = $Margin/VBox/Map

var _refresh_timer := 0.0
## The corner overlay's layer, built when Overlay is first checked.
var _overlay_layer: CanvasLayer = null
var _overlay_map: SimulationMapView = null


func _ready() -> void:
	_speed.clear()
	for speed: float in SPEEDS:
		_speed.add_item("%sx" % speed)
	_speed.item_selected.connect(_on_speed_selected)
	_show_disabled.toggled.connect(_on_show_disabled_toggled)
	_overlay_toggle.toggled.connect(_on_overlay_toggled)
	_map.show_disabled = _show_disabled.button_pressed


func _process(delta: float) -> void:
	var overlay_shown := _overlay_layer != null and _overlay_layer.visible
	if not is_visible_in_tree() and not overlay_shown:
		return
	_refresh_timer -= delta
	if _refresh_timer > 0.0:
		return
	_refresh_timer = REFRESH_SECONDS
	_refresh()


func _refresh() -> void:
	var travel: LowLevelTravel = NpcSimulationServer.low_level_travel
	var selected := SPEEDS.find(travel.speed_scale)
	if selected != -1 and selected != _speed.selected:
		_speed.select(selected)
	var player := ScriptServer.player_reference as ActorReference
	if player == null or not NpcSimulationServer.is_seeded:
		_stats.text = NpcSimulationServer.status
		return
	_map.show_space(player.current_space_form_id, player.position, player)
	if _overlay_layer != null and _overlay_layer.visible:
		_overlay_map.show_space(player.current_space_form_id, player.position, player)
	var counts := _map.count_actors()
	_stats.text = "space %08X   leased %d   moving %d   idle %d   disabled %d   routes not found %d   view %d m" % [
		player.current_space_form_id, counts["leased"], counts["moving"], counts["idle"], counts["disabled"],
		travel.routes_not_found, roundi(_map.radius_metres)]


func _on_speed_selected(index: int) -> void:
	NpcSimulationServer.low_level_travel.speed_scale = SPEEDS[index]


func _on_show_disabled_toggled(pressed: bool) -> void:
	_map.show_disabled = pressed
	_map.queue_redraw()
	if _overlay_map != null:
		_overlay_map.show_disabled = pressed
		_overlay_map.queue_redraw()


func _on_overlay_toggled(pressed: bool) -> void:
	if _overlay_layer == null:
		_build_overlay()
	_overlay_layer.visible = pressed
	_refresh_timer = 0.0


## A second map on its own layer, anchored to the top-right corner, with no
## background and no mouse input so play is unaffected. Its zoom follows the
## tab's map.
func _build_overlay() -> void:
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.name = "SimulationOverlay"
	_overlay_layer.layer = 50
	_overlay_layer.visible = false
	get_tree().root.add_child.call_deferred(_overlay_layer)
	_overlay_map = SimulationMapView.new()
	_overlay_map.draw_background = false
	_overlay_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_map.clip_contents = true
	_overlay_map.show_disabled = _show_disabled.button_pressed
	_overlay_map.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_overlay_map.offset_left = -OVERLAY_SIZE.x - OVERLAY_MARGIN
	_overlay_map.offset_right = -OVERLAY_MARGIN
	_overlay_map.offset_top = OVERLAY_MARGIN
	_overlay_map.offset_bottom = OVERLAY_MARGIN + OVERLAY_SIZE.y
	_overlay_layer.add_child(_overlay_map)
	_map.zoom_changed.connect(func() -> void: _overlay_map.radius_metres = _map.radius_metres)
	_overlay_map.radius_metres = _map.radius_metres
