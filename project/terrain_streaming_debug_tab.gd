extends Control

## Debug Tools -> Terrain Streaming. TerrainStreamer remains the sole owner;
## this tab reads its public diagnostics and exposes only safe scheduler knobs.

const REFRESH_INTERVAL_SEC := 0.25

@onready var _status_card: RichTextLabel = $"Margin/VBox/StateGrid/StatusCard"
@onready var _world_card: RichTextLabel = $"Margin/VBox/StateGrid/WorldCard"
@onready var _domain_card: RichTextLabel = $"Margin/VBox/StateGrid/DomainCard"
@onready var _queue_card: RichTextLabel = $"Margin/VBox/StateGrid/QueueCard"
@onready var _worker_card: RichTextLabel = $"Margin/VBox/StateGrid/WorkerCard"
@onready var _resource_card: RichTextLabel = $"Margin/VBox/StateGrid/ResourceCard"
@onready var _timing_card: RichTextLabel = $"Margin/VBox/TimingCard"
@onready var _regions_per_frame: SpinBox = $"Margin/VBox/TuningRow/RegionsPerFrameSpin"
@onready var _radius: SpinBox = $"Margin/VBox/TuningRow/RadiusSpin"
@onready var _retained_tree: Tree = $"Margin/VBox/RetainedWorldspaces"

var _terrain_streamer: TerrainStreamer
var _refresh_timer := 0.0
var _suppress_tuning_signals := false


func _ready() -> void:
	_terrain_streamer = get_tree().root.get_node_or_null("Game/TerrainStreamer") as TerrainStreamer
	_regions_per_frame.value_changed.connect(_on_regions_per_frame_changed)
	_radius.value_changed.connect(_on_radius_changed)
	_setup_retained_tree()
	_refresh()


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		_refresh_timer = REFRESH_INTERVAL_SEC
		_refresh()


func _on_regions_per_frame_changed(value: float) -> void:
	if _suppress_tuning_signals or _terrain_streamer == null:
		return
	_terrain_streamer.regions_per_frame = int(value)


func _on_radius_changed(value: float) -> void:
	if _suppress_tuning_signals or _terrain_streamer == null:
		return
	_terrain_streamer.load_radius = value


func _setup_retained_tree() -> void:
	_retained_tree.columns = 5
	_retained_tree.column_titles_visible = true
	_retained_tree.hide_root = true
	_retained_tree.select_mode = Tree.SELECT_ROW
	for column in range(5):
		_retained_tree.set_column_expand(column, column == 0)
	_retained_tree.set_column_title(0, "Worldspace")
	_retained_tree.set_column_title(1, "Active")
	_retained_tree.set_column_title(2, "Regions")
	_retained_tree.set_column_title(3, "Textures")
	_retained_tree.set_column_title(4, "Runtime state")


func _refresh() -> void:
	if _terrain_streamer == null:
		_status_card.text = "[color=#e06c75][b]TerrainStreamer not found[/b][/color]"
		return
	var diagnostics := _terrain_streamer.get_diagnostics()
	_refresh_state(diagnostics)
	_refresh_timing(diagnostics)
	_refresh_tuning()
	_refresh_retained_worldspaces(diagnostics.get("retained_worldspaces", {}))


func _refresh_state(diagnostics: Dictionary) -> void:
	var active := bool(diagnostics.get("active", false))
	var paused := bool(diagnostics.get("paused", false))
	if active and not paused:
		_status_card.text = "Status: [color=#98c379][b]ACTIVE[/b][/color]"
	elif active:
		_status_card.text = "Status: [color=#e5c07b][b]PAUSED[/b][/color]"
	else:
		_status_card.text = "Status: [color=#7f848e][b]INACTIVE[/b][/color]"

	var worldspace_id := int(diagnostics.get("worldspace_form_id", -1))
	var worldspace_label := "(none)" if worldspace_id < 0 else "0x%08X" % worldspace_id
	_world_card.text = "World: [b]%s[/b] [color=#7f848e](%s)[/color]" % [worldspace_label, String(diagnostics.get("cache_family", "—"))]
	_domain_card.text = "Domain: [b]%d / %d[/b] committed regions" % [int(diagnostics.get("committed_regions", 0)), int(diagnostics.get("total_regions", 0))]
	_queue_card.text = "Queue: [b]%d[/b] queued  •  [b]%d[/b] preparing  •  [b]%d[/b] prepared" % [int(diagnostics.get("queued_regions", 0)), int(diagnostics.get("preparing_regions", 0)), int(diagnostics.get("prepared_regions", 0))]
	_worker_card.text = "Workers: [b]%d[/b] target  •  [b]%d[/b] abandoned/reaping" % [int(diagnostics.get("worker_count", 0)), int(diagnostics.get("abandoned_workers", 0))]
	_resource_card.text = "Resources: [b]%d[/b] resident cells  •  [b]%d[/b] texture slots  •  [b]%d[/b] collision refreshes" % [int(diagnostics.get("resident_cells", 0)), int(diagnostics.get("texture_slots_used", 0)), int(diagnostics.get("collision_updates", 0))]


func _refresh_timing(diagnostics: Dictionary) -> void:
	var staging: Array = diagnostics.get("staging_ms", [])
	var publication: Array = diagnostics.get("publication_ms", [])
	var total: Array = diagnostics.get("terrain_ms", [])
	_timing_card.text = "[b]CPU samples[/b]  staging p95: [color=#61afef]%.2f ms[/color] (%d)  •  publication p95: [color=#98c379]%.2f ms[/color] (%d)  •  terrain handoff p95: %.2f ms (%d)" % [_p95(staging), staging.size(), _p95(publication), publication.size(), _p95(total), total.size()]


func _refresh_tuning() -> void:
	_suppress_tuning_signals = true
	_regions_per_frame.value = _terrain_streamer.regions_per_frame
	_radius.value = _terrain_streamer.load_radius
	_suppress_tuning_signals = false


func _refresh_retained_worldspaces(entries: Dictionary) -> void:
	_retained_tree.clear()
	var root := _retained_tree.create_item()
	var worldspace_ids: Array = entries.keys()
	worldspace_ids.sort()
	for worldspace_id: int in worldspace_ids:
		var entry: Dictionary = entries[worldspace_id]
		var item := _retained_tree.create_item(root)
		var active := bool(entry.get("active", false))
		item.set_text(0, "0x%08X" % worldspace_id)
		item.set_text(1, "active" if active else "retained")
		item.set_text(2, "%d" % int(entry.get("committed_regions", 0)))
		item.set_text(3, "%d" % int(entry.get("texture_slots_used", 0)))
		item.set_text(4, _entry_runtime_state(entry))
		item.set_custom_color(1, Color("#98c379") if active else Color("#7f848e"))


func _entry_runtime_state(entry: Dictionary) -> String:
	if bool(entry.get("active", false)):
		return "live"
	if not bool(entry.get("terrain_visible", false)) and not bool(entry.get("terrain_physics", false)) and int(entry.get("collision_mode", -1)) == Terrain3DCollision.DISABLED:
		return "suspended"
	return "retained"


func _p95(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return float(sorted[mini(sorted.size() - 1, floori(sorted.size() * 0.95))])
