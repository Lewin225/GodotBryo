extends Control

## Debug Tools window (game.tscn) -> TabContainer -> "World Streaming" tab.
## Read-only + a couple of live-tunable knobs onto the real WorldStreamer
## instance. Structured stat cards replace continuous text dumps to avoid
## scroll jumping.

const REFRESH_INTERVAL_SEC := 0.25

@onready var _status_card: RichTextLabel = $"Margin/SubTabs/Streaming State/VBox/StateGrid/StatusCard"
@onready var _cell_card: RichTextLabel = $"Margin/SubTabs/Streaming State/VBox/StateGrid/CellCard"
@onready var _resident_card: RichTextLabel = $"Margin/SubTabs/Streaming State/VBox/StateGrid/ResidentCard"
@onready var _full_detail_card: RichTextLabel = $"Margin/SubTabs/Streaming State/VBox/StateGrid/FullDetailCard"
@onready var _distant_card: RichTextLabel = $"Margin/SubTabs/Streaming State/VBox/StateGrid/DistantCard"
@onready var _in_flight_card: RichTextLabel = $"Margin/SubTabs/Streaming State/VBox/StateGrid/InFlightCard"
@onready var _queue_depth_card: RichTextLabel = $"Margin/SubTabs/Streaming State/VBox/StateGrid/QueueDepthCard"
@onready var _no_cell_cache_card: RichTextLabel = $"Margin/SubTabs/Streaming State/VBox/StateGrid/NoCellCacheCard"

@onready var _rad_load_full: RichTextLabel = $"Margin/SubTabs/Streaming State/VBox/RadiusGrid/RadLoadFull"
@onready var _rad_unload_full: RichTextLabel = $"Margin/SubTabs/Streaming State/VBox/RadiusGrid/RadUnloadFull"
@onready var _rad_load_distant: RichTextLabel = $"Margin/SubTabs/Streaming State/VBox/RadiusGrid/RadLoadDistant"
@onready var _rad_unload: RichTextLabel = $"Margin/SubTabs/Streaming State/VBox/RadiusGrid/RadUnload"
@onready var _check_interval: RichTextLabel = $"Margin/SubTabs/Streaming State/VBox/RadiusGrid/CheckInterval"
@onready var _lod_crossover: RichTextLabel = $"Margin/SubTabs/Streaming State/VBox/RadiusGrid/LodCrossover"

@onready var _tiles_per_frame_spin: SpinBox = $"Margin/SubTabs/Streaming State/VBox/TuneRow/TilesPerFrameSpin"
@onready var _objects_per_frame_spin: SpinBox = $"Margin/SubTabs/Streaming State/VBox/TuneRow/ObjectsPerFrameSpin"
@onready var _freeze_trace_check: CheckBox = $"Margin/SubTabs/Streaming State/VBox/TuneRow/FreezeTraceCheck"

@onready var _tex_filter_edit: LineEdit = $"Margin/SubTabs/Ground Textures/VBox/TexFilterEdit"
@onready var _texture_tree: Tree = $"Margin/SubTabs/Ground Textures/VBox/TextureTree"
@onready var _texture_summary_label: RichTextLabel = $"Margin/SubTabs/Ground Textures/VBox/TexHeader/TexSummaryLabel"

var _world_streamer: WorldStreamer
var _terrain_streamer: TerrainStreamer
var _refresh_timer := 0.0
var _suppress_spin_signals := false


func _ready() -> void:
	_world_streamer = get_tree().root.get_node_or_null("Game/WorldStreamer") as WorldStreamer
	_terrain_streamer = get_tree().root.get_node_or_null("Game/TerrainStreamer") as TerrainStreamer
	_setup_texture_tree()
	_tiles_per_frame_spin.value_changed.connect(_on_tiles_per_frame_changed)
	_objects_per_frame_spin.value_changed.connect(_on_objects_per_frame_changed)
	_freeze_trace_check.toggled.connect(_on_freeze_trace_toggled)
	_tex_filter_edit.text_changed.connect(func(_t: String) -> void: _refresh_texture_list())
	_refresh()


func _setup_texture_tree() -> void:
	_texture_tree.columns = 2
	_texture_tree.column_titles_visible = true
	_texture_tree.hide_root = true
	_texture_tree.select_mode = Tree.SELECT_ROW

	_texture_tree.set_column_title(0, "Slot")
	_texture_tree.set_column_expand(0, false)
	_texture_tree.set_column_custom_minimum_width(0, 70)

	_texture_tree.set_column_title(1, "Texture Path / Asset Name")
	_texture_tree.set_column_expand(1, true)


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		_refresh_timer = REFRESH_INTERVAL_SEC
		_refresh()


func _on_tiles_per_frame_changed(value: float) -> void:
	if _suppress_spin_signals or _world_streamer == null:
		return
	_world_streamer.tiles_per_frame = int(value)


func _on_objects_per_frame_changed(value: float) -> void:
	if _suppress_spin_signals or _world_streamer == null:
		return
	_world_streamer.objects_per_frame = int(value)


func _on_freeze_trace_toggled(enabled: bool) -> void:
	if _suppress_spin_signals or _world_streamer == null:
		return
	_world_streamer.freeze_trace_enabled = enabled


func _refresh() -> void:
	if _world_streamer == null:
		_status_card.text = "[color=#e06c75]WorldStreamer not found[/color]"
		return
	_refresh_state()
	_refresh_radius_config()
	_refresh_tuning_spinboxes()
	_refresh_texture_list()


func _refresh_state() -> void:
	var ws := _world_streamer
	var terrain_diag := _terrain_streamer.get_diagnostics() if _terrain_streamer != null else {}

	if ws.is_active():
		_status_card.text = "Status: [color=#98c379][b]🟢 ACTIVE[/b][/color]" if not ws.is_paused() else "Status: [color=#e5c07b][b]🟡 PAUSED[/b][/color]"
	else:
		_status_card.text = "Status: [color=#7f848e]⚪ INACTIVE[/color]"

	var cell_form_id := ws.get_current_cell_form_id()
	var cell_label := "(none)"
	if cell_form_id != 0:
		var editor_id: String = ws.esm.get_cell_editor_id(cell_form_id) if ws.esm != null else ""
		cell_label = "[b]%s[/b] [color=#61afef](0x%08X)[/color]" % [editor_id if editor_id != "" else "Cell", cell_form_id]
	_cell_card.text = "Cell: %s" % cell_label

	var full_count: int = ws._resident_full_detail.values().count(true)
	var resident_total: int = ws._resident.size()
	var distant_count: int = resident_total - full_count

	_resident_card.text = "Resident: [b][color=#98c379]%d[/color][/b] objects / [b]%d[/b] terrain" % [resident_total, int(terrain_diag.get("resident_cells", 0))]
	_full_detail_card.text = "Full Detail: [b][color=#61afef]%d[/color][/b]" % full_count
	_distant_card.text = "Distant: [b][color=#e5c07b]%d[/color][/b]" % distant_count
	_in_flight_card.text = "In-Flight: [b]%d[/b] [color=#7f848e](Pend: %d)[/color]" % [ws._in_flight_count, ws._pending.size()]
	_queue_depth_card.text = "Queue Depth: [b]%d[/b] objects / [b]%d[/b] terrain" % [ws._load_queue.size(), int(terrain_diag.get("queued_cells", 0))]
	_no_cell_cache_card.text = "Empty Cache: [b]%d[/b]" % ws._no_cell_cache.size()


func _refresh_radius_config() -> void:
	_rad_load_full.text = "Load Full: [color=#98c379][b]%.1f[/b][/color]" % WorldStreamer.RADIUS_LOAD_FULL
	_rad_unload_full.text = "Unload Full: [color=#e5c07b][b]%.2f[/b][/color]" % WorldStreamer.RADIUS_UNLOAD_FULL
	_rad_load_distant.text = "Load Distant: [color=#61afef][b]%.1f[/b][/color]" % WorldStreamer.RADIUS_LOAD_DISTANT
	_rad_unload.text = "Unload: [color=#e06c75][b]%.1f[/b][/color]" % WorldStreamer.RADIUS_UNLOAD
	_check_interval.text = "Check: [b]%.2fs[/b]" % WorldStreamer.CHECK_INTERVAL_SEC
	_lod_crossover.text = "LOD: [b]%.0fm[/b] [color=#7f848e](±%.0fm)[/color]" % [GodotBryoSettings.lod0_crossover_distance_m, GodotBryoSettings.lod0_crossover_margin_m]


func _refresh_tuning_spinboxes() -> void:
	_suppress_spin_signals = true
	_tiles_per_frame_spin.value = _world_streamer.tiles_per_frame
	_objects_per_frame_spin.value = _world_streamer.objects_per_frame
	_freeze_trace_check.button_pressed = _world_streamer.freeze_trace_enabled
	_suppress_spin_signals = false


func _refresh_texture_list() -> void:
	_texture_tree.clear()
	if _terrain_streamer == null:
		_texture_summary_label.text = "[color=#7f848e](not active)[/color]"
		return

	var diagnostics := _terrain_streamer.get_diagnostics()
	var filter_text := _tex_filter_edit.text.to_lower().strip_edges()
	var entries: Array = diagnostics.get("texture_entries", [])
	_texture_summary_label.text = "[color=#61afef][b]%d[/b][/color] / [color=#7f848e]%d[/color] slots used" % [int(diagnostics.get("texture_slots_used", 0)), Terrain3DTexturePool.USABLE_SLOTS]

	var root := _texture_tree.create_item()
	for entry in entries:
		var name: String = String(entry["name"])
		var slot: int = int(entry["slot"])
		var slot_str := str(slot)
		if not filter_text.is_empty():
			if name.to_lower().find(filter_text) == -1 and slot_str.find(filter_text) == -1:
				continue
		var item := _texture_tree.create_item(root)
		item.set_metadata(0, slot)
		item.set_text(0, slot_str)
		item.set_text_alignment(0, HORIZONTAL_ALIGNMENT_CENTER)
		item.set_custom_color(0, Color("#61afef"))

		item.set_text(1, name)
		item.set_custom_color(1, Color("#e5c07b"))
