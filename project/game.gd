extends Node3D

## The real runtime entry point — not a @tool inspection scene
## (interior_viewer.gd/exterior_viewer.gd) and not a headless test. Loads
## the game's actual default starting cell (GSDocMitchellHouse, the same
## default used throughout Phase 1/2) via CellStreamerV2 on startup.
##
## The player controller ("Character", the FPC addon) is a sibling of
## CellStreamerV2/WorldStreamer in this scene. Neither of those has any idea a
## player exists (phases/2/07-runtime-cell-loader.md,
## phases/2/08-world-cell-streaming.md).
##
## Interact-driven activation dispatch (the old _try_interact()/
## _interact_raycast() pair) has been removed pending the EsmNode.activate()
## outcome rework — see Plans/GameGd/game_gd_decomposition.md item 4. Game
## still owns the transition machinery an activation outcome would drive:
## _do_exterior_transition() and _on_load_completed() route to whichever of
## CellStreamerV2.load_cell() or WorldStreamer.activate() applies for a given
## destination cell (EsmReader.get_cell_worldspace()) — only one of the two is
## ever "where the player is" at a time, so the other is torn down first —
## but neither currently has a caller.
##
## Player repositioning on load: this scene's own "Character" node (a
## CharacterBody3D — the FPC addon's root type) is found and moved directly
## in _on_load_completed() below. For the *initial* spawn (this scene's own
## startup load, not a door transition) there's no XTEL landing transform
## to use — CellStreamerV2 has no concept of "spawn point" either, deliberately
## (phases/2/07-runtime-cell-loader.md). Instead this looks up the cell's
## own "COCMarkerHeading" REFR (Bethesda's own "Center On Cell" reference
## point — the same marker the `coc` console command centers on, confirmed
## present with a real, sensible position in GSDocMitchellHouse, not a
## guess) via CellStreamerV2's typed-reference cache, and falls back to a crude
## drop-from-above-the-AABB heuristic only if a cell genuinely has none.

const DEFAULT_CELL_EDITOR_ID := "GSDocMitchellHouse"
const GameDataConfigScript := preload("res://game_data_config.gd")

# Interact reach: no game-data source for this (it's a pure UX/feel
# constant in the original engine too, not derived from anything in the
# ESM/NIF data) -- picked to comfortably reach a door/lever from just
# outside its collision, not tuned further.
const INTERACT_REACH_METERS := 2.5
const PhysicaliserScript := preload("res://GodotBryo/Pipeline/esm_reference_physicaliser.gd")

## Scene wiring. Exported rather than looked up by $Path in _ready(): a node
## that is renamed or removed then shows as an empty slot in the inspector,
## instead of surfacing as a null dereference at runtime.
@export var cell_streamer: CellStreamerV2
@export var world_streamer: WorldStreamerV2
@export var terrain_streamer: TerrainStreamer
@export var script_engine: ScriptEngine
@export var game_time_manager: GameTimeManager
@export var weather_manager: WeatherManager
@export var celestial_controller: CelestialController
@export var terminal_session: TerminalSession
@export var message_box: MessageBox
@export var cell_label: Label
var _hud_cell_form_id: int = 0 # last cell the HUD was drawn for -- avoids redundant ESM lookups every frame while WorldStreamer is active
@export var sun: DirectionalLight3D
@export var world_environment: WorldEnvironment
## The player. Exported for the same reason as the rest -- it was previously
## bound by the literal node name "Character" alone.
@export var player: CharacterBody3D
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

# Set right before a door-triggered load_cell() call (currently unreachable
# now that interact dispatch is removed; see the class doc comment), so
# _on_load_completed() knows to land the player at the door's own
# XTEL-resolved destination instead of the cell's COCMarkerHeading (which is
# only correct for this scene's own startup load, not a door transition --
# see the class doc comment). Raw ESM-local position/rotation, same
# convention as any other REFR's DATA fields -- converted through the
# newly-loaded cell's own RefrRoot once loading completes, same as
# _find_coc_spawn_transform() does for the marker case.
var _pending_door_spawn: Dictionary = {}
var _shared_esm: EsmReader
var _transition_generation := 0
var _transition_in_progress := false

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
	script_engine.message_box = message_box
	# XCLL owns a separate directional source for interiors.  It is created
	# here rather than authored into game.tscn so the scene's exterior Sun
	# remains its own independently-tunable resource.
	_interior_directional_light = DirectionalLight3D.new()
	_interior_directional_light.name = "InteriorDirectionalLight3D"
	_interior_directional_light.shadow_enabled = true
	_interior_directional_light.visible = false
	add_child(_interior_directional_light)
	_set_exterior_environment(false) # deterministic starting state, not whatever the .tscn happened to have assigned
	cell_streamer.load_started.connect(_on_load_started)
	cell_streamer.load_completed.connect(_on_load_completed)
	if not EsmServer.is_ready():
		await EsmServer.esm_ready
	var typed_esm: EsmReader = EsmServer.reader
	if typed_esm == null:
		push_error("Game: EsmServer did not become ready")
		return
	# Runtime interiors and exteriors share EsmServer's typed reference graph.
	# Terrain keeps its private native reader because that independent pipeline
	# still consumes raw LAND data rather than typed EsmReference resources.
	script_engine.esm = typed_esm
	script_engine.player_node = _get_character_body() # real GECK "player" keyword -- see ScriptEngine's own doc comment
	script_engine.function_registry.place_at_me_handler = debug_place_at_me
	script_engine.function_registry.center_on_cell_handler = debug_center_on_cell
	script_engine.function_registry.game_time_manager = game_time_manager

	# day-night: configure time manager, weather + celestial, but don't activate
	# exterior rendering until the WorldStreamer first goes exterior.
	game_time_manager.configure(typed_esm)
	weather_manager.configure(typed_esm)
	celestial_controller.configure(sun, world_environment, EXTERIOR_ENVIRONMENT, weather_manager)

	var cell: Dictionary = typed_esm.find_cell_by_editor_id(DEFAULT_CELL_EDITOR_ID)
	if cell.is_empty():
		push_error("game.gd: default cell not found: " + DEFAULT_CELL_EDITOR_ID)
		return
	cell_streamer.load_cell(int(cell["form_id"]))

func _on_load_started(cell_form_id: int) -> void:
	print("game.gd: loading cell 0x%X..." % cell_form_id)

func _on_load_completed(cell_form_id: int, success: bool) -> void:
	print("game.gd: cell 0x%X load complete, success=%s" % [cell_form_id, success])
	if not success:
		_pending_door_spawn = {}
		_transition_in_progress = false
		return

	# CellStreamerV2 is only ever used for interior destinations from this scene
	# (see the class doc comment -- an exterior destination routes through
	# WorldStreamer/_do_exterior_transition() instead), so every successful
	# load_completed here means "the player is now indoors."
	_set_exterior_environment(false)
	celestial_controller.set_exterior(false) # stop driving sky/sun while indoors
	weather_manager.set_paused(true)
	_apply_cell_lighting(cell_form_id)
	_update_cell_hud(cell_form_id)

	var spawn := {}
	if not _pending_door_spawn.is_empty():
		spawn = _convert_authored_spawn_transform(_pending_door_spawn["position"], _pending_door_spawn["rotation"])
		_pending_door_spawn = {}
	if spawn.is_empty():
		spawn = _find_coc_spawn_transform()
	if spawn.is_empty():
		spawn = _find_fallback_spawn_transform()
	if not spawn.is_empty():
		reposition_player(spawn["position"], spawn["rotation"])
	_transition_in_progress = false

## Interact raycast, called each frame -- press-E-to-use, same reach/gesture
## for every interactable type this grows to cover (doors now; hover
## prompts and physics-prop dragging are follow-on work sharing this same
## raycast, not separate systems). Deliberately checks `has_method("activate")`
## rather than `is DoorNode`, so adding a new interactable type later never
## needs this function to change -- it just needs to expose the same
## contract (an `activate() -> Dictionary` callable, per DoorNode's own
## established pattern in project/gamebryo/door_node.gd).
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

func debug_drop_inventory_item(base_form_id: int) -> bool:
	push_warning("Drop inventory item is unavailable while the legacy registry is detached from CellStreamerV2")
	return false

## PlaceAtMe's runtime owner.  The function registry delegates here so it
## never needs to know about active cell roots, mesh construction, or the
## scene tree.  FalloutNV accepts Distance/Direction but ignores both in
## practice; use a safe nearby spread instead, and retain the caller's
## actual world rotation (including player look tilt when present).
func debug_place_at_me(args: Array, caller: Node) -> Variant:
	if caller == null or args.is_empty():
		return 0
	push_warning("PlaceAtMe is unavailable while the legacy registry is detached from CellStreamerV2")
	return 0

## Console-only CenterOnCell/COC.  The real command's destination is the
## cell's authored COCMarkerHeading; `_on_load_completed()` already owns
## that exact empty-_pending_door_spawn path, so don't duplicate its spawn
## conversion here.  Exterior grid travel is CenterOnWorld's job and stays
## deliberately separate for this first console pass.
func debug_center_on_cell(args: Array) -> Variant:
	if args.is_empty():
		return { "error": "CenterOnCell requires a cell EditorID." }
	var esm: EsmReader = EsmServer.reader
	if esm == null:
		return { "error": "EsmServer is not ready." }
	var cell: Dictionary = esm.find_cell_by_editor_id(str(args[0]))
	if cell.is_empty():
		return { "error": "No CELL with EditorID '%s' in the loaded ESM." % str(args[0]) }
	var cell_form_id := int(cell["form_id"])
	if esm.get_cell_worldspace(cell_form_id) != -1:
		return { "error": "'%s' is exterior; CenterOnWorld is not implemented yet." % str(args[0]) }
	terrain_streamer.set_paused(true)
	world_streamer.set_paused(true)
	_transition_generation += 1
	_pending_door_spawn = {}
	cell_streamer.load_cell(cell_form_id)
	return cell_form_id


## phases/2/08-world-cell-streaming.md: a door into an exterior worldspace.
## Unlike the interior case, WorldStreamer needs no "load this cell" call --
## reposition the player first (exterior REFR positions are already
## absolute world coordinates, so this needs only the fixed axis
## conversion, not any one tile's own RefrRoot -- see
## _convert_dest_spawn_transform_exterior()), THEN activate() so its very
## first streaming check already sees the player's new position.
func _do_exterior_transition(wrld_form_id: int, local_pos: Vector3, local_rot: Vector3) -> void:
	if _transition_in_progress:
		return
	_transition_in_progress = true
	_transition_generation += 1
	var my_transition := _transition_generation
	var terrain_diag := terrain_streamer.get_diagnostics()
	var same_worldspace := terrain_streamer.is_active() and int(terrain_diag.get("worldspace_form_id", -1)) == wrld_form_id
	if not same_worldspace:
		world_streamer.deactivate()
		# TerrainStreamer retains entries within the active ESM's cache family
		# itself. Its following activate() suspends the outgoing terrain before
		# selecting or creating the destination entry; do not final-teardown it here.
	cell_streamer.unload_current() # only one of CellStreamerV2/WorldStreamer is ever live
	_set_exterior_environment(true)
	# day-night: load CLMT for this worldspace and tell celestial to drive the sky.
	weather_manager.activate_worldspace(wrld_form_id)
	celestial_controller.set_exterior(true)
	var spawn := _convert_dest_spawn_transform_exterior(local_pos, local_rot)
	reposition_player(spawn["position"], spawn["rotation"])

	# Freeze the body for the duration of the initial streaming catch-up --
	# without this, gravity keeps applying every physics frame while the
	# destination's own terrain/collision is still streaming in behind the
	# scenes, and the body falls through the world before it's ready.
	# set_physics_process(false) stops the FPC addon's own gravity/movement
	# processing entirely (it's all driven from CharacterBody3D's own
	# _physics_process()), not just gravity specifically -- also freezes
	# input, which is fine/expected here (matches the "release the body
	# once streaming_settled fires" design this signal was built for).
	var body := _get_character_body()
	if body != null:
		body.set_physics_process(false)
		if "velocity" in body:
			body.velocity = Vector3.ZERO

	var object_ready := [false]
	var settled_callback := func() -> void: object_ready[0] = true
	world_streamer.streaming_settled.connect(settled_callback)
	if same_worldspace:
		terrain_streamer.set_paused(false)
		world_streamer.activate(wrld_form_id)
	else:
		terrain_streamer.activate(wrld_form_id)
		world_streamer.activate(wrld_form_id)
	var terrain_generation := terrain_streamer.get_generation()
	var spawn_coord := Vector2i(floori(spawn["position"].x / TerrainStreamer.CELL_SIZE_METERS), floori(-spawn["position"].z / TerrainStreamer.CELL_SIZE_METERS))
	var terrain_status := await terrain_streamer.await_ready_for(wrld_form_id, spawn_coord, terrain_generation)
	while not object_ready[0] and my_transition == _transition_generation:
		await get_tree().process_frame
	if world_streamer.streaming_settled.is_connected(settled_callback):
		world_streamer.streaming_settled.disconnect(settled_callback)
	if not _can_release_exterior_transition(my_transition, terrain_status, object_ready[0]):
		_transition_in_progress = false
		return

	if body != null:
		if "velocity" in body:
			body.velocity = Vector3.ZERO # discard whatever residual state accumulated, if any
		body.set_physics_process(true)

	var cell_form_id := world_streamer.get_current_cell_form_id()
	if cell_form_id != 0:
		_update_cell_hud(cell_form_id)
	_transition_in_progress = false

func _can_release_exterior_transition(generation: int, terrain_status: TerrainStreamer.ReadyStatus, object_ready: bool) -> bool:
	return generation == _transition_generation \
			and terrain_status == TerrainStreamer.ReadyStatus.READY \
			and object_ready

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

## Converts a raw XTEL destination into Godot world space for an EXTERIOR
## landing cell -- unlike _convert_authored_spawn_transform() below, there's no
## per-tile root to convert through here (WorldStreamer may have several, or
## none yet, resident). Exterior REFR positions are absolute world coordinates;
## the shared physicaliser applies the one authored Z-up -> Godot Y-up
## conversion, with no additional tile offset.
func _convert_dest_spawn_transform_exterior(local_pos: Vector3, local_rot: Vector3) -> Dictionary:
	return _convert_authored_spawn_transform(local_pos, local_rot)

## Converts a raw XTEL destination (same ESM-local convention as any REFR's
## DATA position/rotation) into Godot world space through the same public
## transform used by EsmReferencePhysicaliser -- identical math to
## _find_coc_spawn_transform() below, just fed a door's destination instead
## of a marker's.
func _convert_authored_spawn_transform(local_pos: Vector3, local_rot: Vector3) -> Dictionary:
	var transform := PhysicaliserScript.placement_transform(local_pos, local_rot)
	return { "position": transform.origin, "rotation": Vector3(0, transform.basis.get_euler().y, 0) }

## Bethesda's own "Center On Cell" reference marker — a real, per-cell REFR
## (base_editor_id "COCMarkerHeading", model MarkerCOCHeading.nif),
## confirmed present in GSDocMitchellHouse with a sensible in-room position.
## Its position/rotation are in the same local Bethesda Z-up space as every
## other REFR — converted by EsmReferencePhysicaliser's same shared transform,
## not by duplicating Z-up -> Y-up rotation math in Game.
func _find_coc_spawn_transform() -> Dictionary:
	if cell_streamer == null or cell_streamer._current == null:
		return {}
	var marker := cell_streamer.find_ref_by_editor_id("COCMarkerHeading")
	if marker == null:
		return {}
	return _convert_authored_spawn_transform(marker.position, marker.rotation)

## Last-resort fallback for a cell with no COCMarkerHeading (should be rare
## — every cell the `coc` console command can target has one — but not
## guaranteed universal, so this exists rather than leaving the player
## unpositioned). Drops from above the cell's whole bounding box and lets
## gravity/collision settle it — not guaranteed to land in the "right" room
## for a multi-level interior, a known limitation of this fallback only.
func _find_fallback_spawn_transform() -> Dictionary:
	var combined: Variant = _current_cell_aabb()
	if combined == null:
		return {}
	var spawn_xz: Vector3 = combined.get_center()
	var drop_from := Vector3(spawn_xz.x, combined.position.y + combined.size.y + 1.0, spawn_xz.z)
	return { "position": drop_from, "rotation": Vector3.ZERO }

## Moves the player's CharacterBody3D directly (a physics body's transform
## can be set outright — this isn't move_and_slide()) and zeroes its
## velocity so no leftover momentum carries from wherever it was into the
## new cell. `rot` is Euler radians (only Y — yaw — is used).
##
## Setting the CharacterBody3D's own `rotation` directly does NOT turn the
## FPC addon's movement direction — confirmed in its own source
## (addons/fpc/character.gd): _ready() copies the body's initial
## rotation.y into a separate "HEAD" child node ONCE, then resets the
## body's own rotation.y to 0, and _handle_movement() computes movement
## direction purely from HEAD.rotation.y from then on, never the body's.
## Rotating the body after that (what this function used to do) visually
## re-faces the camera correctly (it hangs off HEAD, a child of the body,
## so it inherits the body's world orientation) while leaving the
## *movement* basis stuck at whatever HEAD.rotation.y was at scene start —
## a fixed-offset "controls feel rotated" bug (e.g. LEFT moving you
## forward). Set HEAD's own rotation.y instead, and leave the body's
## rotation untouched, so both stay in sync.
func reposition_player(pos: Vector3, rot: Vector3) -> void:
	var body := _get_character_body()
	if body == null:
		push_warning("game.gd: no CharacterBody3D found to reposition")
		return
	if body.has_method("teleport"):
		body.teleport(pos)
	else:
		body.global_position = pos
	if "camera_pitch" in body:
		body.camera_pitch = 0.0
	if "HEAD" in body and body.HEAD != null:
		body.HEAD.rotation.y = rot.y
	else:
		body.rotation.y = rot.y
	if "velocity" in body:
		body.velocity = Vector3.ZERO

## This used to recurse from Game through its entire subtree. Character is
## after CellStreamerV2 in game.tscn, so every lookup first traversed streamed
## cell content; that is why one logical interaction lookup became hundreds
## of profiler calls. Re-resolve only the authored direct child if the cache
## was invalidated by a future character replacement.
func _get_character_body() -> CharacterBody3D:
	return player if is_instance_valid(player) else null

## Returns the currently-loaded cell's combined world-space AABB (from its
## MeshInstance3D descendants), or null if nothing is loaded / has no
## geometry.
func _current_cell_aabb() -> Variant:
	if cell_streamer == null or cell_streamer._current == null:
		return null
	var combined := AABB()
	var have := false
	for mi in _mesh_instances(cell_streamer._current):
		var wa: AABB = mi.global_transform * mi.mesh.get_aabb()
		combined = wa if not have else combined.merge(wa)
		have = true
	return combined if have else null

func _mesh_instances(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_mesh_instances(c))
	return out
