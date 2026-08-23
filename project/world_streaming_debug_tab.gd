extends Control

## Debug Tools window (game.tscn) -> TabContainer -> "World Streaming" tab.
## Read-only + a couple of live-tunable knobs onto the real WorldStreamer
## instance. UI is scene-authored (game.tscn, under this node) rather than
## built from code -- deliberately, so this tab stays an easy place to keep
## adding more debug controls by hand in the editor, not a script anyone has
## to extend to add a widget. This script only wires already-placed nodes up
## to real data and refreshes them -- it owns no layout.
##
## Deliberately excludes the mesh/texture/material resource-cache stats
## (GamebryoMeshResolver.get_cache_stats(), the "nif cache") -- that's scoped
## to the not-yet-built ESMReader debug tab instead, not this one. This tab
## is WorldStreamer's own streaming state plus the real Terrain3D ground
## texture pool it owns, per explicit direction.
##
## WorldStreamer is found via the scene tree, not a direct scene-authored
## reference -- this Control lives under Debug Tools/TabContainer, a sibling
## subtree of WorldStreamer, not a descendant of it. game.tscn's own root
## node is named "Game" and is this project's run/main_scene
## (project.godot), so get_tree().root.get_node("Game") resolves reliably
## regardless of where Debug Tools itself ends up parented later.
const REFRESH_INTERVAL_SEC := 0.25

@onready var _state_label: RichTextLabel = $Margin/VBox/StateLabel
@onready var _radius_label: RichTextLabel = $Margin/VBox/RadiusLabel
@onready var _tiles_per_frame_spin: SpinBox = $Margin/VBox/TuneRow/TilesPerFrameSpin
@onready var _objects_per_frame_spin: SpinBox = $Margin/VBox/TuneRow/ObjectsPerFrameSpin
@onready var _texture_list: ItemList = $Margin/VBox/TextureList
@onready var _texture_summary_label: Label = $Margin/VBox/TexHeader/TexSummaryLabel

var _world_streamer: WorldStreamer
var _refresh_timer := 0.0
var _suppress_spin_signals := false # true while _refresh() writes the spinboxes' own current values back, so that write doesn't re-trigger the user-edit handler

func _ready() -> void:
	_world_streamer = get_tree().root.get_node("Game/WorldStreamer")
	_tiles_per_frame_spin.value_changed.connect(_on_tiles_per_frame_changed)
	_objects_per_frame_spin.value_changed.connect(_on_objects_per_frame_changed)
	_refresh() # paint real values immediately, don't wait for the first timer tick

func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return # this tab isn't the active one (or the Debug Tools window itself is hidden) -- no point paying for a report nobody sees
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

func _refresh() -> void:
	if _world_streamer == null:
		_state_label.text = "(WorldStreamer node not found)"
		return
	_refresh_state()
	_refresh_radius_config()
	_refresh_tuning_spinboxes()
	_refresh_texture_list()

func _refresh_state() -> void:
	var ws := _world_streamer
	var lines := PackedStringArray()
	lines.append("active: %s   paused: %s" % [ws.is_active(), ws.is_paused()])
	if ws.is_active():
		var cell_form_id := ws.get_current_cell_form_id()
		var cell_label := "0x%X" % cell_form_id if cell_form_id != 0 else "(none)"
		if cell_form_id != 0:
			var editor_id: String = ws.esm.get_cell_editor_id(cell_form_id)
			if editor_id != "":
				cell_label = "%s (0x%X)" % [editor_id, cell_form_id]
		lines.append("current cell: %s" % cell_label)
	lines.append("resident tiles: %d   pending: %d   queued: %d   in-flight: %d" % [
		ws._resident.size(), ws._pending.size(), ws._queued.size(), ws._in_flight_count,
	])
	lines.append("load queue running: %s   queue depth: %d" % [ws._load_queue_running, ws._load_queue.size()])
	lines.append("persistent root loaded: %s" % (ws._persistent_root != null))
	lines.append("no-cell cache size: %d  (confirmed-empty grid coords for this worldspace)" % ws._no_cell_cache.size())
	lines.append("full-detail resident tiles: %d / %d" % [
		ws._resident_full_detail.values().count(true), ws._resident.size(),
	])
	_state_label.text = "\n".join(lines)

func _refresh_radius_config() -> void:
	var lines := PackedStringArray()
	lines.append("RADIUS_LOAD_FULL:    %.1f  (every placement resolved within this)" % WorldStreamer.RADIUS_LOAD_FULL)
	lines.append("RADIUS_UNLOAD_FULL:  %.1f  (full-detail tiles downgrade past this)" % WorldStreamer.RADIUS_UNLOAD_FULL)
	lines.append("RADIUS_LOAD_DISTANT: %.1f  (VWD-only placements out to this)" % WorldStreamer.RADIUS_LOAD_DISTANT)
	lines.append("RADIUS_UNLOAD:       %.1f  (tiles freed entirely past this)" % WorldStreamer.RADIUS_UNLOAD)
	lines.append("CHECK_INTERVAL_SEC:  %.2f" % WorldStreamer.CHECK_INTERVAL_SEC)
	lines.append("use_terrain3d: %s   prewarm_terrain_textures: %s" % [_world_streamer.use_terrain3d, _world_streamer.prewarm_terrain_textures])
	lines.append("lod_crossover: %.1fm  margin: %.1fm" % [_world_streamer.lod_crossover_distance_m, _world_streamer.lod_crossover_margin_m])
	_radius_label.text = "\n".join(lines)

func _refresh_tuning_spinboxes() -> void:
	_suppress_spin_signals = true
	_tiles_per_frame_spin.value = _world_streamer.tiles_per_frame
	_objects_per_frame_spin.value = _world_streamer.objects_per_frame
	_suppress_spin_signals = false

func _refresh_texture_list() -> void:
	var pool: Terrain3DTexturePool = _world_streamer._terrain3d_pool
	_texture_list.clear()
	if pool == null:
		_texture_summary_label.text = "  (not using Terrain3D / not active)"
		return
	var entries: Array = pool.get_debug_texture_list()
	_texture_summary_label.text = "  %d / %d slots used" % [pool.used_slot_count(), Terrain3DTexturePool.USABLE_SLOTS]
	for entry in entries:
		_texture_list.add_item("slot %3d   %s" % [entry["slot"], entry["name"]])
