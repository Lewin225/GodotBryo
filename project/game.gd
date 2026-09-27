extends Node3D

## The runtime entry point. Wires the scene's servers and nodes, gives the
## player controller the player's reference to possess, and starts the game by
## moving that reference to DEFAULT_CELL_EDITOR_ID's COC marker.
##
## Loading follows the possessed reference (TransitionCoordinator). Game reacts
## to where the player ends up: interior/exterior environment, XCLL lighting,
## weather and sky, and the debug HUD.

const DEFAULT_CELL_EDITOR_ID := "GSDocMitchellHouse"
const GameDataConfigScript := preload("res://game_data_config.gd")


## Scene wiring. Exported rather than looked up by $Path in _ready(): a node
## that is renamed or removed then shows as an empty slot in the inspector,
## instead of surfacing as a null dereference at runtime.
@export var cell_streamer: CellStreamerV2
@export var world_streamer: WorldStreamerV2
@export var terrain_streamer: TerrainStreamer
@export var transition_coordinator: TransitionCoordinator
@export var game_time_manager: GameTimeManager
@export var weather_manager: WeatherManager
@export var celestial_controller: CelestialController
@export var cell_label: Label
var _hud_cell_form_id: int = 0 # last cell the HUD was drawn for -- avoids redundant ESM lookups every frame while WorldStreamer is active
@export var sun: DirectionalLight3D
@export var world_environment: WorldEnvironment
## The player. Exported for the same reason as the rest -- it was previously
## bound by the literal node name "Character" alone.
@export var player: PlayerController
var _interior_directional_light: DirectionalLight3D
var inventory := Inventory.new()

# DebugStats.gd's own F3 overlay moved to a real editor debugger panel
# (world_streaming_debug_tab.gd) -- StatsLabel removed here, no longer
# duplicated. F3 itself is currently unbound to anything in this file.
#
# Standalone .tres files (not inline .tscn sub-resources) so each is
# independently editable/previewable in the editor -- WorldEnvironment
# nodes can't be individually enabled/disabled (tried; Godot has no such
# toggle), so a single WorldEnvironment node swaps which resource it
# points to instead. Assign either one directly to the WorldEnvironment
# node in the editor to preview it there without needing Play mode.
const INTERIOR_ENVIRONMENT := preload("res://interior_environment.tres")
const EXTERIOR_ENVIRONMENT := preload("res://exterior_environment.tres")
const GAMEBRYO_UNITS_TO_METERS := 1.0 / 70.0

var _shared_esm: EsmReader

func _enter_tree() -> void:
	var configuration: Dictionary = GameDataConfigScript.resolve()
	var data_dir := String(configuration.get("data_dir", ""))
	if data_dir.is_empty():
		push_error("Game: " + String(configuration.get("error", "no game data directory")))
		return
	_shared_esm = EsmReader.new()
	if not _shared_esm.open(data_dir + GameDataConfigScript.ESM_FILE):
		push_error("Game: could not open FalloutNV.esm")
		return
	cell_streamer = get_node("CellStreamerV2") as CellStreamerV2
	world_streamer = get_node("WorldStreamerV2") as WorldStreamerV2
	terrain_streamer = get_node("TerrainStreamer") as TerrainStreamer
	terrain_streamer.configure(_shared_esm)

func _ready() -> void:
	# XCLL owns a separate directional source for interiors.  It is created
	# here rather than authored into game.tscn so the scene's exterior Sun
	# remains its own independently-tunable resource.
	_interior_directional_light = DirectionalLight3D.new()
	_interior_directional_light.name = "InteriorDirectionalLight3D"
	_interior_directional_light.shadow_enabled = true
	_interior_directional_light.visible = false
	add_child(_interior_directional_light)
	_set_exterior_environment(false) # deterministic starting state, not whatever the .tscn happened to have assigned
	transition_coordinator.entered_interior.connect(_on_entered_interior)
	transition_coordinator.entered_exterior.connect(_on_entered_exterior)
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var typed_esm: EsmReader = EsmServer.reader
	if typed_esm == null:
		push_error("Game: EsmServer did not become ready")
		return
	# Runtime interiors and exteriors share EsmServer's typed reference graph.
	# Terrain keeps its private native reader because that independent pipeline
	# still consumes raw LAND data rather than typed EsmReference resources.
	player.possess(EsmServer.get_player_reference())
	ScriptServer.function_registry.place_at_me_handler = debug_place_at_me
	ScriptServer.function_registry.center_on_cell_handler = transition_coordinator.center_on_cell
	ScriptServer.function_registry.game_time_manager = game_time_manager

	# day-night: configure time manager, weather + celestial, but don't activate
	# exterior rendering until the WorldStreamer first goes exterior.
	game_time_manager.configure(typed_esm)
	weather_manager.configure(typed_esm)
	celestial_controller.configure(sun, world_environment, EXTERIOR_ENVIRONMENT, weather_manager)

	QuestServer.begin_game()
	# VCG00 plays the intro and hands over to VCG01 (Ain't That a Kick in the
	# Head); the player starts with VCG01 as the active quest.
	QuestServer.active_quest = EsmServer.find_quest_by_editor_id("VCG01")
	var start: Variant = transition_coordinator.center_on_cell([DEFAULT_CELL_EDITOR_ID])
	if start is Dictionary:
		push_error("game.gd: " + String(start["error"]))

func _on_entered_interior(cell_form_id: int) -> void:
	_set_exterior_environment(false)
	celestial_controller.set_exterior(false)
	weather_manager.set_paused(true)
	_apply_cell_lighting(cell_form_id)
	_update_cell_hud(cell_form_id)

func _on_entered_exterior(worldspace_form_id: int) -> void:
	_set_exterior_environment(true)
	weather_manager.activate_worldspace(worldspace_form_id)
	celestial_controller.set_exterior(true)

## Keeps the HUD's cell label current while streaming exteriors and advances
## the clock-driven sky and weather.
func _process(_delta: float) -> void:
	if world_streamer != null and world_streamer.is_active() and not world_streamer.is_paused():
		var current_cell_form_id := world_streamer.get_current_cell_form_id()
		if current_cell_form_id != 0 and current_cell_form_id != _hud_cell_form_id:
			_update_cell_hud(current_cell_form_id) # refreshed continuously while streaming -- the "current cell" changes as the player walks, unlike CellStreamerV2's single-load case
	if cell_streamer == null or cell_streamer.is_loading():
		return # a load is already in flight -- don't stack another
	# day-night: advance clock-driven environment every frame.
	if game_time_manager != null and celestial_controller != null:
		var climate := weather_manager.climate if weather_manager != null else {}
		if not climate.is_empty():
			celestial_controller.update(game_time_manager.game_hour, climate)
			weather_manager.advance(_delta * game_time_manager.timescale / 3600.0)

func debug_add_inventory_item(base_form_id: int) -> bool:
	for entry in inventory.get_entries():
		if int(entry.get("base_form_id", 0)) == base_form_id:
			inventory.add_item(base_form_id, entry)
			return true
	return false

func debug_drop_inventory_item(_base_form_id: int) -> bool:
	push_warning("Drop inventory item is unavailable while the legacy registry is detached from CellStreamerV2")
	return false

## PlaceAtMe's runtime owner.  The function registry delegates here so it
## never needs to know about active cell roots, mesh construction, or the
## scene tree.  FalloutNV accepts Distance/Direction but ignores both in
## practice; use a safe nearby spread instead, and retain the caller's
## actual world rotation (including player look tilt when present).
func debug_place_at_me(args: Array, caller: EsmReference) -> Variant:
	if caller == null or args.is_empty():
		return 0
	push_warning("PlaceAtMe is unavailable while the legacy registry is detached from CellStreamerV2")
	return 0

## Rendering-issues list #1: interiors don't have a real sky/sun -- Bethesda
## interior cells are always fully enclosed geometry with their own baked
## lighting, so a shared exterior skybox/directional light bleeding through
## walls (or a flat exterior-sky-colored background showing past any
## unmodeled gap) reads as wrong.
##
## Two standalone .tres Environment resources (INTERIOR_ENVIRONMENT/
## EXTERIOR_ENVIRONMENT above), each independently editor-tunable, swapped
## onto the scene's single WorldEnvironment node -- deliberately not one
## shared Environment with fields mutated by script (the first version of
## this fix did that: hand-tuning either look in the editor's Inspector
## needs a real resource to select and preview, not runtime-computed values
## you can't see or drag a slider on), and not two separate WorldEnvironment
## nodes either (tried; Godot has no per-node enable/disable for those, so
## having two simultaneously in the tree was ambiguous about which won).
func _set_exterior_environment(is_exterior: bool) -> void:
	if sun != null:
		sun.visible = is_exterior
	if _interior_directional_light != null:
		_interior_directional_light.visible = false
	if world_environment != null:
		world_environment.environment = EXTERIOR_ENVIRONMENT if is_exterior else INTERIOR_ENVIRONMENT

## CELL.XCLL stores the directional source as Bethesda/Gamebryo X and Z
## Euler degrees.  The named XY field is the first (X) rotation in the
## on-disk pair; the second is the Z rotation.  Reuse the REFR conversion so
## the same Z-up -> Y-up and sign conventions apply to both authored data
## sources.  DirectionalLight3D emits along local -Z, so this first-pass
## conversion includes a final half-turn to make the common real 0/270 pair
## vertically downward in Godot. DirectionalLight3D emits along its local
## forward (-Z) axis, so this uses the same Gamebryo-to-Godot conversion as
## placements with no additional half-turn.
static func _xcll_directional_basis(rotation_xy_degrees: int, rotation_z_degrees: int) -> Basis:
	var raw_rotation := Vector3(deg_to_rad(float(rotation_xy_degrees)), 0.0, deg_to_rad(float(rotation_z_degrees)))
	return EsmReferencePhysicaliser.GAMEBRYO_TO_GODOT_BASIS * EsmReferencePhysicaliser.authored_rotation_basis(raw_rotation)

## CELL.XCLL's own per-cell authored ambient color, layered on top of the
## shared INTERIOR_ENVIRONMENT.tres baseline (energy/tonemap/SDFGI/SSAO/etc
## all stay exactly as hand-tuned there -- only ambient_light_color is
## overridden). Duplicates the base resource per load rather than mutating
## INTERIOR_ENVIRONMENT itself, which stays the shared, editor-tunable
## fallback for any cell with no XCLL (a real, common case -- e.g. exterior
## cells, or an interior cell whose designer never touched the lighting tab)
## -- get_cell_lighting_data() returns {} for those, and this just leaves
## INTERIOR_ENVIRONMENT itself assigned, same as before this feature existed.
## Only called for interior (CellStreamerV2) loads -- WorldStreamer's exterior
## cells use EXTERIOR_ENVIRONMENT's own flat sky-driven lighting instead.
func _apply_cell_lighting(cell_form_id: int) -> void:
	var esm: EsmReader = EsmServer.reader
	if world_environment == null or esm == null:
		return
	var lighting: Dictionary = esm.get_cell_lighting_data(cell_form_id)
	if lighting.is_empty():
		return
	var env: Environment = INTERIOR_ENVIRONMENT.duplicate()
	env.ambient_light_color = lighting["ambient_color"]
	# LGTM/XCLL directional fields are interior-lighting metadata, not proof of
	# a world-spanning sun. Doc Mitchell's enclosed cell inherits one from its
	# generic template; mapping it to a shadow-casting DirectionalLight3D made
	# it cast through the roof. Keep the authored values parsed/debuggable, but
	# leave this disabled until the Gamebryo static/interior lighting path is
	# represented rather than approximating it as a direct sun.
	_interior_directional_light.visible = false
	# XCLL fog distances share the Gamebryo-world-unit convention used by
	# REFR transforms, LAND, and LIGH radius. Godot's depth-fog distances are
	# metres, so preserve the authored range after this one conversion.
	var fog_near_m := maxf(float(lighting.get("fog_near", 0.0)) * GAMEBRYO_UNITS_TO_METERS, 0.0)
	var fog_far_m := maxf(float(lighting.get("fog_far", 0.0)) * GAMEBRYO_UNITS_TO_METERS, fog_near_m)
	if fog_far_m > fog_near_m:
		env.fog_enabled = true
		env.fog_light_color = lighting["fog_color"]
		env.fog_depth_begin = fog_near_m
		env.fog_depth_end = fog_far_m
		# XCLL calls this Fog Power; Godot's depth curve is likewise the
		# non-linear shaping control between the authored near/far bounds.
		# This is an explicit same-semantics approximation to verify in play.
		env.fog_depth_curve = maxf(float(lighting.get("fog_power", 1.0)), 0.001)
	else:
		env.fog_enabled = false
	world_environment.environment = env

func _apply_xcll_directional_light(lighting: Dictionary) -> void:
	if _interior_directional_light == null:
		return
	var color: Color = lighting["directional_color"]
	# A black resolved directional colour is an explicit no-light value, not
	# a request to fall back to the exterior Sun. LTMP/LNAM inheritance was
	# already resolved by EsmReader before this point.
	var energy := maxf(float(lighting.get("directional_fade", 0.0)), 0.0)
	_interior_directional_light.light_color = color
	_interior_directional_light.light_energy = energy
	_interior_directional_light.basis = _xcll_directional_basis(
			int(lighting.get("directional_rotation_xy", 0)),
			int(lighting.get("directional_rotation_z", 0)))
	_interior_directional_light.visible = energy > 0.0 and (color.r > 0.0 or color.g > 0.0 or color.b > 0.0)

## Debug HUD: current cell's own EditorID, plus its worldspace grid
## coordinate when it's an exterior cell (get_exterior_cell_grid() returns
## {} for interior cells -- a real, valid case, not an error, per its own
## doc comment in esm_reader_gd.h).
func _update_cell_hud(cell_form_id: int) -> void:
	if cell_label == null:
		return
	_hud_cell_form_id = cell_form_id
	var esm: EsmReader = EsmServer.reader
	if esm == null:
		return
	var editor_id: String = esm.get_cell_editor_id(cell_form_id)
	var label: String = editor_id if editor_id != "" else "0x%X" % cell_form_id
	var grid: Dictionary = esm.get_exterior_cell_grid(cell_form_id)
	if not grid.is_empty():
		label += " (%d, %d)" % [int(grid["x"]), int(grid["y"])]
	cell_label.text = "cell: " + label
