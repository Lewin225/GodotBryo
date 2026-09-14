extends Node3D

## The real runtime entry point — not a @tool inspection scene
## (interior_viewer.gd/exterior_viewer.gd) and not a headless test. Loads
## the game's actual default starting cell (GSDocMitchellHouse, the same
## default used throughout Phase 1/2) via CellStreamerV2 on startup.
##
## The player controller ("Character", the FPC addon) is a sibling of
## CellStreamerV2/WorldStreamer in this scene. Neither of those has any idea a
## player exists (phases/2/07-runtime-cell-loader.md,
## phases/2/08-world-cell-streaming.md) — _process() below owns the interact
## raycast instead: on a hit against anything exposing
## activate() -> Dictionary (DoorNode today; any future interactable type
## needs only that same contract, not a change here), it checks whether the
## destination is interior or exterior (EsmReader.get_cell_worldspace()) and
## routes to whichever of CellStreamerV2.load_cell() or
## WorldStreamer.activate() applies — only one of the two is ever "where
## the player is" at a time, so the other is torn down first. See
## _try_interact()/_on_load_completed()/_do_exterior_transition() below.
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
const ITEM_DRAG_HOLD_SECONDS := 0.28
const DEBUG_MENU_SHOW_EDITOR_OBJECTS := 100

const PhysicaliserScript := preload("res://GodotBryo/Pipeline/esm_reference_physicaliser.gd")

var cell_streamer: CellStreamerV2
var world_streamer: WorldStreamerV2
var terrain_streamer: TerrainStreamer
var script_engine: ScriptEngine
var game_time_manager: GameTimeManager
var weather_manager: WeatherManager
var celestial_controller: CelestialController
var terminal_session: TerminalSession
var message_box: MessageBox
var _cell_label: Label
var _hud_cell_form_id: int = 0 # last cell the HUD was drawn for -- avoids redundant ESM lookups every frame while WorldStreamer is active
var _sun: DirectionalLight3D
var _interior_directional_light: DirectionalLight3D
var _world_environment: WorldEnvironment
var inventory := Inventory.new()
var _pending_item: ItemNode = null
var _dragging_item: ItemNode = null
var _item_press_time_msec := 0

# The player is a scene-authored direct child (game.tscn: Character), not a
# dynamically discovered gameplay object.  Keep a validated cache instead of
# recursively walking every streamed CellStreamerV2 child before reaching it.
var _character_body: CharacterBody3D = null

# DebugStats.gd's own F3 overlay moved to a real editor debugger panel
# (world_streaming_debug_tab.gd) -- StatsLabel removed here, no longer
# duplicated.
#
# F3 (freed up above) now toggles this instead: what the interact raycast is
# currently looking at. Typed pipeline content resolves its hit NIF physics
# child back to the ancestor EsmNode and reports its EsmReference/EsmBase;
# legacy GamebryoReference content keeps its editor_description fallback.
var _look_at_label: Label
var _debug_menu: PopupMenu

# Standalone .tres files (not inline .tscn sub-resources) so each is
# independently editable/previewable in the editor -- WorldEnvironment
# nodes can't be individually enabled/disabled (tried; Godot has no such
# toggle), so a single WorldEnvironment node swaps which resource it
# points to instead. Assign either one directly to the WorldEnvironment
# node in the editor to preview it there without needing Play mode.
const INTERIOR_ENVIRONMENT := preload("res://interior_environment.tres")
const EXTERIOR_ENVIRONMENT := preload("res://exterior_environment.tres")
const GAMEBRYO_UNITS_TO_METERS := 1.0 / 70.0

# Set by _try_interact() right before a door-triggered load_cell() call, so
# _on_load_completed() knows to land the player at the door's own
# XTEL-resolved destination instead of the cell's COCMarkerHeading (which is
# only correct for this scene's own startup load, not a door transition --
# see the class doc comment). Raw ESM-local position/rotation, same
# convention as any other REFR's DATA fields -- converted through the
# newly-loaded cell's own RefrRoot once loading completes, same as
# _find_coc_spawn_transform() does for the marker case.
var _pending_door_spawn: Dictionary = {}
var _shared_esm: EsmReader
var _shared_resolver: GamebryoMeshResolver
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
	_shared_resolver = GamebryoMeshResolver.new(data_dir)
	cell_streamer = get_node("CellStreamerV2") as CellStreamerV2
	world_streamer = get_node("WorldStreamer") as WorldStreamerV2
	terrain_streamer = get_node("TerrainStreamer") as TerrainStreamer
	terrain_streamer.configure(_shared_esm, _shared_resolver)

func _ready() -> void:
	cell_streamer = $CellStreamerV2 # scene-authored typed interior double buffer
	world_streamer = $WorldStreamer
	terrain_streamer = $TerrainStreamer
	script_engine = $ScriptEngine
	game_time_manager = $GameTimeManager
	weather_manager = $WeatherManager
	celestial_controller = $CelestialController
	terminal_session = $TerminalSession
	message_box = $MessageBox
	script_engine.message_box = message_box
	_cell_label = $DebugHud/CellLabel
	_look_at_label = $DebugHud/LookAtLabel
	_sun = $Sun
	_world_environment = $WorldEnvironment
	_debug_menu = $MenuBar/Debug
	_debug_menu.id_pressed.connect(_on_debug_menu_id_pressed)
	_sync_editor_object_menu()
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
	var typed_esm := await _await_typed_esm()
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
	celestial_controller.configure(_sun, _world_environment, EXTERIOR_ENVIRONMENT, weather_manager)

	var cell: Dictionary = typed_esm.find_cell_by_editor_id(DEFAULT_CELL_EDITOR_ID)
	if cell.is_empty():
		push_error("game.gd: default cell not found: " + DEFAULT_CELL_EDITOR_ID)
		return
	cell_streamer.load_cell(int(cell["form_id"]))

func _on_load_started(cell_form_id: int) -> void:
	print("game.gd: loading cell 0x%X..." % cell_form_id)

func _on_debug_menu_id_pressed(id: int) -> void:
	if id != DEBUG_MENU_SHOW_EDITOR_OBJECTS:
		return
	var nif_server := get_tree().root.get_node_or_null("NifServer")
	if nif_server == null or not nif_server.has_method("set_editor_objects_visible"):
		push_warning("Game: NifServer editor-object policy is unavailable")
		return
	nif_server.set_editor_objects_visible(not bool(nif_server.editor_objects_visible))
	_sync_editor_object_menu()

func _sync_editor_object_menu() -> void:
	if _debug_menu == null:
		return
	var index := _debug_menu.get_item_index(DEBUG_MENU_SHOW_EDITOR_OBJECTS)
	if index < 0:
		return
	var nif_server := get_tree().root.get_node_or_null("NifServer") if get_tree() != null else null
	_debug_menu.set_item_checked(index, true if nif_server == null else bool(nif_server.editor_objects_visible))

func _await_typed_esm() -> EsmReader:
	var server := get_tree().root.get_node_or_null("EsmServer")
	if server == null:
		return null
	if not server.is_ready():
		await server.esm_ready
	return server.reader as EsmReader if server.is_ready() else null

func _typed_esm_reader() -> EsmReader:
	var server := get_tree().root.get_node_or_null("EsmServer") if get_tree() != null else null
	return server.reader as EsmReader if server != null and server.is_ready() else null

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
	if Input.is_action_just_pressed("toggle_stats") and _look_at_label != null:
		_look_at_label.visible = not _look_at_label.visible
	if _look_at_label != null and _look_at_label.visible:
		_update_look_at_label()
	if world_streamer != null and world_streamer.is_active() and not world_streamer.is_paused():
		var current_cell_form_id := world_streamer.get_current_cell_form_id()
		if current_cell_form_id != 0 and current_cell_form_id != _hud_cell_form_id:
			_update_cell_hud(current_cell_form_id) # refreshed continuously while streaming -- the "current cell" changes as the player walks, unlike CellStreamerV2's single-load case
	if cell_streamer == null or cell_streamer.is_loading():
		return # a load is already in flight -- don't stack another
	_update_item_interaction()
	# day-night: advance clock-driven environment every frame.
	if game_time_manager != null and celestial_controller != null:
		var climate := weather_manager.climate if weather_manager != null else {}
		if not climate.is_empty():
			celestial_controller.update(game_time_manager.game_hour, climate)
			weather_manager.advance(_delta * game_time_manager.timescale / 3600.0)

## Shared by _try_interact() and _update_look_at_label() -- the same
## reach/gesture raycast, run either on an actual interact press or every
## frame just to see what's being looked at. Returns {} if nothing usable
## was hit, else { "collider": Object, "target": Object } -- `target` is
## `collider` itself, or (for a Dynamic type's real collision, which lands
## on its internal GamebryoCollisionBody child, not the GamebryoReference
## itself -- enginedocs/nv_class_hierarchy.md: composed, not inherited)
## the resolved owner_ref.
func _interact_raycast() -> Dictionary:
	var player := _get_character_body()
	if player == null:
		return {}
	if "interact_ray" in player and player.interact_ray != null and player.interact_ray is InteractRay:
		return player.interact_ray.get_interact_info()
	if not ("CAMERA" in player) or player.CAMERA == null:
		return {}
	var camera: Camera3D = player.CAMERA
	var from: Vector3 = camera.global_position
	var to: Vector3 = from - camera.global_transform.basis.z * INTERACT_REACH_METERS
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [player.get_rid()]
	var result: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	if result.is_empty():
		return {}
	var collider: Object = result.get("collider")
	if collider == null or collider == player or (collider is Node and player.is_ancestor_of(collider)):
		return {}
	var target: Object = collider
	if collider is GamebryoCollisionBody or collider is GamebryoRigidBody:
		target = collider.owner_ref
	var esm_node := _find_esm_node_ancestor(target)
	if esm_node == null:
		esm_node = _find_esm_node_ancestor(collider)
	if esm_node != null:
		target = esm_node
	if target == player or (target is Node and player.is_ancestor_of(target)):
		return {}
	return { "collider": collider, "target": target }

## F3-toggled (see _process()). Reuses _interact_raycast() unconditionally
## every frame while visible. Typed NIF collision lands on a nested physics
## body, so recover the ancestor EsmNode; retain the legacy editor-description
## path for legacy content in inspection scenes; runtime interiors are typed.
func _update_look_at_label() -> void:
	var hit := _interact_raycast()
	if hit.is_empty():
		_look_at_label.text = ""
		return
	var collider: Object = hit["collider"]
	var target: Object = hit["target"]
	var text := "hit: %s" % String(collider.name)
	if target != collider and target != null:
		text += "\nowner: %s" % String(target.name)
	var esm_node := _find_esm_node_ancestor(target)
	if esm_node == null:
		esm_node = _find_esm_node_ancestor(collider)
	if esm_node != null:
		text += "\nEsmNode: %s\n%s" % [esm_node.name, esm_node.get_debug_description()]
	elif target != null and "editor_description" in target:
		text += "\n" + String(target.editor_description)
	_look_at_label.text = text

## NifServer's StaticBody3D/CollisionShape3D tree has no legacy owner_ref.
## The semantic EsmNode is its ancestor and is the durable ESM identity.
func _find_esm_node_ancestor(object: Object) -> EsmNode:
	if not object is Node:
		return null
	var node := object as Node
	while node != null:
		if node is EsmNode:
			return node
		node = node.get_parent()
	return null

## Tap E picks up an ItemNode; holding E for a short deliberate threshold
## drags it instead. This preserves the existing one-key interact UX while
## making both actions reachable without introducing a speculative binding.
func _update_item_interaction() -> void:
	if Input.is_action_just_pressed("interact"):
		var hit := _interact_raycast()
		var target: Object = hit.get("target") if not hit.is_empty() else null
		if target is ItemNode:
			_pending_item = target
			_item_press_time_msec = Time.get_ticks_msec()
		else:
			_try_interact()
	if _pending_item != null and Input.is_action_pressed("interact") and _dragging_item == null:
		if Time.get_ticks_msec() - _item_press_time_msec >= int(ITEM_DRAG_HOLD_SECONDS * 1000.0):
			var player := _get_character_body()
			if player != null and "CAMERA" in player and _pending_item.begin_drag(player.CAMERA):
				_dragging_item = _pending_item
			_pending_item = null
	if Input.is_action_just_released("interact"):
		if _dragging_item != null:
			_dragging_item.end_drag()
			_dragging_item = null
		elif _pending_item != null:
			_pickup_item(_pending_item)
		_pending_item = null

func _pickup_item(target: Object) -> void:
	var picked: Dictionary = target.pickup()
	if picked.is_empty(): return
	inventory.add_item(int(picked["base_form_id"]), picked["item_data"], int(picked.get("count", 1)))
	if target is Node:
		target.queue_free()

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
	var esm := _typed_esm_reader()
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

## Dynamic types split into two real interact shapes right now: DoorNode
## (the only real has_method("activate") case) still always calls its own
## activate() directly, unconditionally -- this project's own known,
## documented gap (phases/5/00-script-interpreter-foundation.md): a real
## scripted door's default open/close behavior should be gated BEHIND its
## own script explicitly calling `activate` (confirmed against
## GSDocMitchellDoorScript's own real body), not run unconditionally the
## way it is today. Fixing that needs dispatch_event() to propagate a
## script-triggered activate() call's own outcome (the teleport-destination
## Dictionary) back out to this caller, which doesn't exist yet -- real,
## deliberately separate follow-up, not touched here.
##
## Everything else scripted (CONT/ACTI/etc, which have no activate() method
## at all) gets real OnActivate dispatch instead -- confirmed real and
## necessary via GSBrokenSMGScript, a real ACTI in GSDocMitchellHouse whose
## whole OnActivate body (ShowMessage) never ran at all before this,
## since nothing called target.activate() for a type that doesn't have one.
## Mutually exclusive with the door branch on purpose: this doesn't touch
## door behavior at all, sidestepping the outcome-propagation gap above
## entirely for this real, narrower fix.
func _try_interact() -> void:
	if _transition_in_progress:
		return
	var hit := _interact_raycast()
	if hit.is_empty():
		return
	var target: Object = hit["target"]
	if target == null:
		return
	if target.has_method("pickup"):
		_pickup_item(target)
		return
	if target is TerminalNode:
		# TERM browsing is a Game-owned session, not an activate() outcome or
		# a script side effect. Locking, conditions and menu scripts remain
		# explicitly outside this first pass; TerminalSession displays those
		# unavailable choices rather than silently executing or hiding them.
		terminal_session.open_session(target, _typed_esm_reader(), _get_character_body())
		return
	if not target.has_method("activate"):
		if script_engine != null and script_engine.is_scripted(target):
			script_engine.dispatch_event(target, "OnActivate", _get_character_body())
		return
	var outcome: Dictionary = target.activate(_get_character_body()) if target is EsmNode else target.activate()
	if outcome.has("terminal"):
		terminal_session.open_session(outcome["terminal"], _typed_esm_reader(), _get_character_body())
		return
	if outcome.is_empty():
		return # a valid interactable with nothing to do right now (e.g. a non-teleporting door)
	if not outcome.has("dest_cell_form_id"):
		push_warning("Game: activate() returned an unsupported outcome from %s" % target.name)
		return

	var dest_cell_form_id := int(outcome["dest_cell_form_id"])
	var esm := _typed_esm_reader()
	if esm == null:
		return
	var dest_wrld_form_id: int = esm.get_cell_worldspace(dest_cell_form_id)
	if dest_wrld_form_id == -1:
		# Interior destination -- CellStreamerV2's typed single-active-cell
		# path. Only one of CellStreamerV2/WorldStreamer is ever "where the
		# player is" at a time, but PAUSE the exterior streaming rather than
		# deactivate() it -- this game's RAM budget has no reason to pay
		# activate()'s full re-stream/re-texture cost on every single door
		# back outside (a real, measured multi-second stall per door) the
		# way the original Xbox 360 port's 512MB constraint would have
		# forced. WorldStreamerV2 retains semantic roots, hides them, and
		# disables their Node-based collision while the interior is active.
		_transition_in_progress = true
		_transition_generation += 1
		terrain_streamer.set_paused(true)
		world_streamer.set_paused(true)
		_pending_door_spawn = { "position": outcome["dest_position"], "rotation": outcome["dest_rotation"] }
		cell_streamer.load_cell(dest_cell_form_id)
	else:
		_do_exterior_transition(dest_wrld_form_id, outcome["dest_position"], outcome["dest_rotation"])

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

	# Freeze the player for the duration of the initial streaming catch-up --
	# without this, gravity keeps applying every physics frame while the
	# destination's own terrain/collision is still streaming in behind the
	# scenes, and the player falls through the world before it's ready.
	# set_physics_process(false) stops the FPC addon's own gravity/movement
	# processing entirely (it's all driven from CharacterBody3D's own
	# _physics_process()), not just gravity specifically -- also freezes
	# input, which is fine/expected here (matches the "release the player
	# once streaming_settled fires" design this signal was built for).
	var player := _get_character_body()
	if player != null:
		player.set_physics_process(false)
		if "velocity" in player:
			player.velocity = Vector3.ZERO

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

	if player != null:
		if "velocity" in player:
			player.velocity = Vector3.ZERO # discard whatever residual state accumulated, if any
		player.set_physics_process(true)

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
	if _sun != null:
		_sun.visible = is_exterior
	if _interior_directional_light != null:
		_interior_directional_light.visible = false
	if _world_environment != null:
		_world_environment.environment = EXTERIOR_ENVIRONMENT if is_exterior else INTERIOR_ENVIRONMENT

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
	return GamebryoMeshResolver.refr_root_basis() * GamebryoMeshResolver.refr_basis(raw_rotation)

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
	var esm := _typed_esm_reader()
	if _world_environment == null or esm == null:
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
	_world_environment.environment = env

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
	if _cell_label == null:
		return
	_hud_cell_form_id = cell_form_id
	var esm := _typed_esm_reader()
	if esm == null:
		return
	var editor_id: String = esm.get_cell_editor_id(cell_form_id)
	var label: String = editor_id if editor_id != "" else "0x%X" % cell_form_id
	var grid: Dictionary = esm.get_exterior_cell_grid(cell_form_id)
	if not grid.is_empty():
		label += " (%d, %d)" % [int(grid["x"]), int(grid["y"])]
	_cell_label.text = "cell: " + label

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
	var player := _get_character_body()
	if player == null:
		push_warning("game.gd: no CharacterBody3D found to reposition")
		return
	if player.has_method("teleport"):
		player.teleport(pos)
	else:
		player.global_position = pos
	if "camera_pitch" in player:
		player.camera_pitch = 0.0
	if "HEAD" in player and player.HEAD != null:
		player.HEAD.rotation.y = rot.y
	else:
		player.rotation.y = rot.y
	if "velocity" in player:
		player.velocity = Vector3.ZERO

## This used to recurse from Game through its entire subtree. Character is
## after CellStreamerV2 in game.tscn, so every lookup first traversed streamed
## cell content; that is why one logical interaction lookup became hundreds
## of profiler calls. Re-resolve only the authored direct child if the cache
## was invalidated by a future character replacement.
func _get_character_body() -> CharacterBody3D:
	if is_instance_valid(_character_body):
		return _character_body
	_character_body = get_node_or_null(^"Character") as CharacterBody3D
	return _character_body

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
