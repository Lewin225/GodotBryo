extends Control

## Debug Tools -> World Streaming -> WorldStreamerV2 Profiler. This panel is
## intentionally about typed exterior-cell scheduling only. Terrain residency
## and its texture pool live in Terrain Streaming, their actual owner.

const REFRESH_INTERVAL_SEC := 0.2

@onready var _status: RichTextLabel = $"Margin/SubTabs/V2 Profiler/Margin/VBox/StateGrid/Status"
@onready var _camera: RichTextLabel = $"Margin/SubTabs/V2 Profiler/Margin/VBox/StateGrid/Camera"
@onready var _cell: RichTextLabel = $"Margin/SubTabs/V2 Profiler/Margin/VBox/StateGrid/Cell"
@onready var _resident: RichTextLabel = $"Margin/SubTabs/V2 Profiler/Margin/VBox/StateGrid/Resident"
@onready var _persistent: RichTextLabel = $"Margin/SubTabs/V2 Profiler/Margin/VBox/StateGrid/Persistent"
@onready var _tile_queue: RichTextLabel = $"Margin/SubTabs/V2 Profiler/Margin/VBox/StateGrid/TileQueue"
@onready var _population: RichTextLabel = $"Margin/SubTabs/V2 Profiler/Margin/VBox/StateGrid/Population"
@onready var _imposters: RichTextLabel = $"Margin/SubTabs/V2 Profiler/Margin/VBox/StateGrid/Imposters"
@onready var _nif_resolves: RichTextLabel = $"Margin/SubTabs/V2 Profiler/Margin/VBox/NifGrid/Resolves"
@onready var _nif_builds: RichTextLabel = $"Margin/SubTabs/V2 Profiler/Margin/VBox/NifGrid/Builds"
@onready var _nif_cache: RichTextLabel = $"Margin/SubTabs/V2 Profiler/Margin/VBox/NifGrid/Cache"
@onready var _queue_preview: RichTextLabel = $"Margin/SubTabs/V2 Profiler/Margin/VBox/QueuePreview"

@onready var _load_radius: SpinBox = $"Margin/SubTabs/V2 Profiler/Margin/VBox/ConfigGrid/LoadRadius"
@onready var _lod_radius: SpinBox = $"Margin/SubTabs/V2 Profiler/Margin/VBox/ConfigGrid/LodRadius"
@onready var _tiles_per_frame: SpinBox = $"Margin/SubTabs/V2 Profiler/Margin/VBox/ConfigGrid/TilesPerFrame"
@onready var _objects_per_frame: SpinBox = $"Margin/SubTabs/V2 Profiler/Margin/VBox/ConfigGrid/ObjectsPerFrame"
@onready var _spawn_refr: CheckBox = $"Margin/SubTabs/V2 Profiler/Margin/VBox/SpawnTypes/REFR"
@onready var _spawn_achr: CheckBox = $"Margin/SubTabs/V2 Profiler/Margin/VBox/SpawnTypes/ACHR"
@onready var _spawn_crea: CheckBox = $"Margin/SubTabs/V2 Profiler/Margin/VBox/SpawnTypes/CREA"
@onready var _streaming_mode: OptionButton = $"Margin/SubTabs/V2 Profiler/Margin/VBox/Actions/StreamingMode"
@onready var _refresh_now: Button = $"Margin/SubTabs/V2 Profiler/Margin/VBox/Actions/RefreshNow"

var _world_streamer: WorldStreamerV2
var _nif_server: Node
var _refresh_timer := 0.0
var _suppress_config_signals := false


func _ready() -> void:
	_world_streamer = get_tree().root.get_node_or_null("Game/WorldStreamerV2") as WorldStreamerV2
	_nif_server = get_tree().root.get_node_or_null("NifServer")
	_load_radius.value_changed.connect(func(value: float) -> void: _set_config("load_radius", value))
	_lod_radius.value_changed.connect(func(value: float) -> void: _set_config("lod_load_radius", value))
	_tiles_per_frame.value_changed.connect(func(value: float) -> void: _set_config("tiles_per_frame", int(value)))
	_objects_per_frame.value_changed.connect(func(value: float) -> void: _set_config("objects_per_frame", int(value)))
	_spawn_refr.toggled.connect(func(_enabled: bool) -> void: _apply_spawn_types())
	_spawn_achr.toggled.connect(func(_enabled: bool) -> void: _apply_spawn_types())
	_spawn_crea.toggled.connect(func(_enabled: bool) -> void: _apply_spawn_types())
	_streaming_mode.item_selected.connect(_on_streaming_mode_selected)
	_refresh_now.pressed.connect(_on_refresh_now_pressed)
	_refresh()


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		_refresh_timer = REFRESH_INTERVAL_SEC
		_refresh()


func _set_config(property: StringName, value: Variant) -> void:
	if _suppress_config_signals or _world_streamer == null:
		return
	_world_streamer.set(property, value)


func _apply_spawn_types() -> void:
	if _suppress_config_signals or _world_streamer == null:
		return
	var flags := 0
	if _spawn_refr.button_pressed:
		flags |= WorldStreamerV2.SPAWN_REFR
	if _spawn_achr.button_pressed:
		flags |= WorldStreamerV2.SPAWN_ACHR
	if _spawn_crea.button_pressed:
		flags |= WorldStreamerV2.SPAWN_CREA
	_world_streamer.spawn_reference_types = flags


func _on_streaming_mode_selected(mode: int) -> void:
	if _suppress_config_signals or _world_streamer == null or not _world_streamer.is_active():
		return
	match mode:
		0: _world_streamer.set_paused(false)
		1: _world_streamer.set_paused(true, false)
		2: _world_streamer.set_paused(true, true)

func _on_refresh_now_pressed() -> void:
	if _world_streamer != null:
		_world_streamer.call("_check_streaming")


func _refresh() -> void:
	if _world_streamer == null:
		_status.text = "[color=#e06c75][b]WorldStreamerV2 not found[/b][/color]"
		return
	_refresh_state()
	_refresh_nif_pressure()
	_refresh_config()


func _refresh_state() -> void:
	var ws := _world_streamer
	if not ws.is_active():
		_status.text = "[color=#7f848e][b]INACTIVE[/b][/color]"
	elif ws.is_paused():
		_status.text = "[color=#e5c07b][b]PAUSED[/b][/color]"
	else:
		_status.text = "[color=#98c379][b]ACTIVE[/b][/color]  %.1f FPS" % Engine.get_frames_per_second()
	var camera_grid: Variant = ws._current_grid_coord()
	_camera.text = "Camera grid: [b]%s[/b]" % (str(camera_grid) if camera_grid != null else "—")
	var form_id := ws.get_current_cell_form_id()
	var editor_id := ""
	if form_id != 0 and ws.esm_server != null and ws.esm_server.reader != null:
		editor_id = ws.esm_server.reader.get_cell_editor_id(form_id)
	_cell.text = "Current cell: [b]%s[/b] [color=#61afef]0x%08X[/color]" % [editor_id if not editor_id.is_empty() else "—", form_id]
	var full_detail := 0
	for root: Node3D in ws._resident.values():
		if int(root.get_meta("visual_detail", EsmNode.VisualDetail.FULL)) == EsmNode.VisualDetail.FULL:
			full_detail += 1
	_resident.text = "Resident tiles: [b]%d[/b]  •  [color=#61afef]%d full[/color]" % [ws._resident.size(), full_detail]
	_persistent.text = "Persistent tiles: [b]%d[/b]  •  [color=#e5c07b]%d populating[/color]" % [ws._persistent_tiles.size(), ws._persistent_pending.size()]
	_tile_queue.text = "Tile starts: [b]%d[/b] ordinary  •  [b]%d[/b] persistent" % [ws._load_queue.size(), ws._persistent_load_queue.size()]
	_population.text = "Population jobs: [b]%d[/b] ordinary  •  [b]%d[/b] persistent" % [ws._tile_population_jobs.size(), ws._persistent_population_jobs.size()]
	_imposters.text = "Deferred XSRF/XSRD imposters: [b]%d[/b]  •  empty-cell cache: [b]%d[/b]" % [ws._persistent_imposter_queue.size(), ws._no_cell_cache.size()]
	_queue_preview.text = "[color=#7f848e]Nearest pending tiles[/color]\nordinary: %s\npersistent: %s" % [_format_coords(ws._load_queue), _format_coords(ws._persistent_load_queue)]


func _refresh_nif_pressure() -> void:
	if _nif_server == null or not _nif_server.has_method("get_stats"):
		_nif_resolves.text = "[color=#7f848e]NifServer unavailable[/color]"
		_nif_builds.text = ""
		_nif_cache.text = ""
		return
	var stats: Dictionary = _nif_server.get_stats()
	_nif_resolves.text = "Resolves: [b]%d[/b] active  •  [b]%d[/b] awaiting worker" % [int(stats.get("active_resolve_count", 0)), int(stats.get("pending_admission_count", 0))]
	_nif_builds.text = "Build queue: [b]%d[/b]  •  [b]%d[/b] this frame" % [int(stats.get("pending_build_count", 0)), int(stats.get("builds_this_frame", 0))]
	_nif_cache.text = "Cache Size: [b]%d[/b] trees / [b]%d[/b] documents" % [int(stats.get("resident_tree_count", 0)), int(stats.get("resident_document_count", 0))]


func _refresh_config() -> void:
	_suppress_config_signals = true
	_load_radius.value = _world_streamer.load_radius
	_lod_radius.value = _world_streamer.lod_load_radius
	_tiles_per_frame.value = _world_streamer.tiles_per_frame
	_objects_per_frame.value = _world_streamer.objects_per_frame
	var flags := _world_streamer.spawn_reference_types
	_spawn_refr.button_pressed = (flags & WorldStreamerV2.SPAWN_REFR) != 0
	_spawn_achr.button_pressed = (flags & WorldStreamerV2.SPAWN_ACHR) != 0
	_spawn_crea.button_pressed = (flags & WorldStreamerV2.SPAWN_CREA) != 0
	_streaming_mode.disabled = not _world_streamer.is_active()
	_streaming_mode.select(0 if not _world_streamer.is_paused() else (2 if _world_streamer.is_pause_hiding() else 1))
	_refresh_now.disabled = not _world_streamer.is_active()
	_suppress_config_signals = false

func _format_coords(coords: Array[Vector2i]) -> String:
	if coords.is_empty():
		return "—"
	var result: Array[String] = []
	for index in mini(6, coords.size()):
		result.append(str(coords[index]))
	return ", ".join(result) + (" …" if coords.size() > result.size() else "")
