extends Node3D

## The real runtime entry point — not a @tool inspection scene
## (interior_viewer.gd/exterior_viewer.gd) and not a headless test. Loads
## the game's actual default starting cell (GSDocMitchellHouse, the same
## default used throughout Phase 1/2) via CellLoader on startup.
##
## The player controller ("Character", the FPC addon) is a sibling of
## CellLoader/WorldStreamer in this scene. Neither of those has any idea a
## player exists (phases/2/07-runtime-cell-loader.md,
## phases/2/08-world-cell-streaming.md) — _process() below owns the interact
## raycast instead: on a hit against anything exposing
## activate() -> Dictionary (DoorNode today; any future interactable type
## needs only that same contract, not a change here), it checks whether the
## destination is interior or exterior (EsmReader.get_cell_worldspace()) and
## routes to whichever of CellLoader.load_cell() or
## WorldStreamer.activate() applies — only one of the two is ever "where
## the player is" at a time, so the other is torn down first. See
## _try_interact()/_on_load_completed()/_do_exterior_transition() below.
##
## Player repositioning on load: this scene's own "Character" node (a
## CharacterBody3D — the FPC addon's root type) is found and moved directly
## in _on_load_completed() below. For the *initial* spawn (this scene's own
## startup load, not a door transition) there's no XTEL landing transform
## to use — CellLoader has no concept of "spawn point" either, deliberately
## (phases/2/07-runtime-cell-loader.md). Instead this looks up the cell's
## own "COCMarkerHeading" REFR (Bethesda's own "Center On Cell" reference
## point — the same marker the `coc` console command centers on, confirmed
## present with a real, sensible position in GSDocMitchellHouse, not a
## guess) via CellLoader's xref cache, and falls back to a crude
## drop-from-above-the-AABB heuristic only if a cell genuinely has none.

const DEFAULT_CELL_EDITOR_ID := "GSDocMitchellHouse"

# Interact reach: no game-data source for this (it's a pure UX/feel
# constant in the original engine too, not derived from anything in the
# ESM/NIF data) -- picked to comfortably reach a door/lever from just
# outside its collision, not tuned further.
const INTERACT_REACH_METERS := 2.5

var cell_loader: CellLoader
var world_streamer: WorldStreamer
var script_engine: ScriptEngine
var _cell_label: Label
var _hud_cell_form_id: int = 0 # last cell the HUD was drawn for -- avoids redundant ESM lookups every frame while WorldStreamer is active
var _sun: DirectionalLight3D
var _world_environment: WorldEnvironment

# DebugStats.gd's own F3 overlay moved to a real editor debugger panel
# (world_streaming_debug_tab.gd) -- StatsLabel removed here, no longer
# duplicated.
#
# F3 (freed up above) now toggles this instead: what the interact raycast
# is currently looking at, by node name + GamebryoReference's own
# editor_description (base_type/editor_id/form_ids/model, already built
# in _finalize() for every real placement) -- built to make it fast to
# identify which real DOOR/asset a given piece of world geometry actually
# is while walking around in Play, instead of hunting for it blind
# through ESM data (e.g. tracking down a specific bugged door instance).
var _look_at_label: Label

# Standalone .tres files (not inline .tscn sub-resources) so each is
# independently editable/previewable in the editor -- WorldEnvironment
# nodes can't be individually enabled/disabled (tried; Godot has no such
# toggle), so a single WorldEnvironment node swaps which resource it
# points to instead. Assign either one directly to the WorldEnvironment
# node in the editor to preview it there without needing Play mode.
const INTERIOR_ENVIRONMENT := preload("res://interior_environment.tres")
const EXTERIOR_ENVIRONMENT := preload("res://exterior_environment.tres")

# Set by _try_interact() right before a door-triggered load_cell() call, so
# _on_load_completed() knows to land the player at the door's own
# XTEL-resolved destination instead of the cell's COCMarkerHeading (which is
# only correct for this scene's own startup load, not a door transition --
# see the class doc comment). Raw ESM-local position/rotation, same
# convention as any other REFR's DATA fields -- converted through the
# newly-loaded cell's own RefrRoot once loading completes, same as
# _find_coc_spawn_transform() does for the marker case.
var _pending_door_spawn: Dictionary = {}

func _ready() -> void:
	cell_loader = $CellLoader # a real scene-tree node now (see game.tscn), not code-instantiated
	world_streamer = $WorldStreamer
	script_engine = $ScriptEngine
	_cell_label = $DebugHud/CellLabel
	_look_at_label = $DebugHud/LookAtLabel
	_sun = $Sun
	_world_environment = $WorldEnvironment
	_set_exterior_environment(false) # deterministic starting state, not whatever the .tscn happened to have assigned
	cell_loader.load_started.connect(_on_load_started)
	cell_loader.load_completed.connect(_on_load_completed)
	await get_tree().process_frame # let CellLoader's own _ready() open the ESM

	# Reuse CellLoader's already-open EsmReader rather than opening a second
	# one -- same convention _apply_cell_lighting() below already uses.
	# Wired into both real object_registry.gd instances (interior + exterior)
	# here, once, rather than each loader reaching for it itself -- neither
	# CellLoader nor WorldStreamer has any reason to know a ScriptEngine
	# exists at all otherwise (phases/5/00-script-interpreter-foundation.md).
	script_engine.esm = cell_loader.esm
	cell_loader.registry.script_engine = script_engine
	world_streamer.registry.script_engine = script_engine

	var cell: Dictionary = cell_loader.esm.find_cell_by_editor_id(DEFAULT_CELL_EDITOR_ID)
	if cell.is_empty():
		push_error("game.gd: default cell not found: " + DEFAULT_CELL_EDITOR_ID)
		return
	cell_loader.load_cell(int(cell["form_id"]))

func _on_load_started(cell_form_id: int) -> void:
	print("game.gd: loading cell 0x%X..." % cell_form_id)

func _on_load_completed(cell_form_id: int, success: bool) -> void:
	print("game.gd: cell 0x%X load complete, success=%s" % [cell_form_id, success])
	if not success:
		_pending_door_spawn = {}
		return

	# CellLoader is only ever used for interior destinations from this scene
	# (see the class doc comment -- an exterior destination routes through
	# WorldStreamer/_do_exterior_transition() instead), so every successful
	# load_completed here means "the player is now indoors."
	_set_exterior_environment(false)
	_apply_cell_lighting(cell_form_id)
	_update_cell_hud(cell_form_id)

	var spawn := {}
	if not _pending_door_spawn.is_empty():
		spawn = _convert_dest_spawn_transform(_pending_door_spawn["position"], _pending_door_spawn["rotation"])
		_pending_door_spawn = {}
	if spawn.is_empty():
		spawn = _find_coc_spawn_transform()
	if spawn.is_empty():
		spawn = _find_fallback_spawn_transform()
	if not spawn.is_empty():
		reposition_player(spawn["position"], spawn["rotation"])

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
	if world_streamer != null and world_streamer.is_active():
		var current_cell_form_id := world_streamer.get_current_cell_form_id()
		if current_cell_form_id != 0 and current_cell_form_id != _hud_cell_form_id:
			_update_cell_hud(current_cell_form_id) # refreshed continuously while streaming -- the "current cell" changes as the player walks, unlike CellLoader's single-load case
	if cell_loader == null or cell_loader._loading:
		return # a load is already in flight -- don't stack another
	if Input.is_action_just_pressed("interact"):
		_try_interact()

## Shared by _try_interact() and _update_look_at_label() -- the same
## reach/gesture raycast, run either on an actual interact press or every
## frame just to see what's being looked at. Returns {} if nothing usable
## was hit, else { "collider": Object, "target": Object } -- `target` is
## `collider` itself, or (for a Dynamic type's real collision, which lands
## on its internal GamebryoCollisionBody child, not the GamebryoReference
## itself -- enginedocs/nv_class_hierarchy.md: composed, not inherited)
## the resolved owner_ref.
func _interact_raycast() -> Dictionary:
	var player := _find_character_body(self)
	if player == null or not ("CAMERA" in player) or player.CAMERA == null:
		return {}
	var camera: Camera3D = player.CAMERA
	var from: Vector3 = camera.global_position
	var to: Vector3 = from - camera.global_transform.basis.z * INTERACT_REACH_METERS
	var query := PhysicsRayQueryParameters3D.create(from, to)
	var result: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	if result.is_empty():
		return {}
	var collider: Object = result.get("collider")
	if collider == null:
		return {}
	var target: Object = collider
	if collider is GamebryoCollisionBody:
		target = collider.owner_ref
	return { "collider": collider, "target": target }

## F3-toggled (see _process()). Reuses _interact_raycast() unconditionally
## every frame while visible -- one raycast is cheap, and this is a
## debug-only feature. `target.editor_description` (built once in
## GamebryoObjectRegistry._finalize() for every real placement -- base_type,
## editor_id, base/refr form_id, and model path when there is one) is
## already exactly the information needed to identify a specific real
## asset by eye instead of guessing which ESM record it is; this just
## displays it, no new data plumbing.
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
	if target != null and "editor_description" in target:
		text += "\n" + String(target.editor_description)
	_look_at_label.text = text

func _try_interact() -> void:
	var hit := _interact_raycast()
	if hit.is_empty():
		return
	var target: Object = hit["target"]
	if target == null or not target.has_method("activate"):
		return
	var outcome: Dictionary = target.activate()
	if outcome.is_empty():
		return # a valid interactable with nothing to do right now (e.g. a non-teleporting door)

	var dest_cell_form_id := int(outcome["dest_cell_form_id"])
	var dest_wrld_form_id: int = cell_loader.esm.get_cell_worldspace(dest_cell_form_id)
	if dest_wrld_form_id == -1:
		# Interior destination -- CellLoader's existing single-active-cell
		# path. Only one of CellLoader/WorldStreamer is ever "where the
		# player is" at a time, but PAUSE the exterior streaming rather than
		# deactivate() it -- this game's RAM budget has no reason to pay
		# activate()'s full re-stream/re-texture cost on every single door
		# back outside (a real, measured multi-second stall per door) the
		# way the original Xbox 360 port's 512MB constraint would have
		# forced. See WorldStreamer.set_paused()'s own doc comment for what
		# "paused" actually has to cover (RenderingServer AND PhysicsServer,
		# not just Node visibility).
		world_streamer.set_paused(true)
		_pending_door_spawn = { "position": outcome["dest_position"], "rotation": outcome["dest_rotation"] }
		cell_loader.load_cell(dest_cell_form_id)
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
	cell_loader.unload_current() # only one of CellLoader/WorldStreamer is ever "live" at a time
	_set_exterior_environment(true)
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
	var player := _find_character_body(self)
	if player != null:
		player.set_physics_process(false)
		if "velocity" in player:
			player.velocity = Vector3.ZERO

	world_streamer.activate(wrld_form_id)
	await world_streamer.streaming_settled # lets a future loading-screen UI know when it's safe to release the player -- WorldStreamer itself has no idea a screen exists

	if player != null:
		if "velocity" in player:
			player.velocity = Vector3.ZERO # discard whatever residual state accumulated, if any
		player.set_physics_process(true)

	var cell_form_id := world_streamer.get_current_cell_form_id()
	if cell_form_id != 0:
		_update_cell_hud(cell_form_id)

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
	if _world_environment != null:
		_world_environment.environment = EXTERIOR_ENVIRONMENT if is_exterior else INTERIOR_ENVIRONMENT

## CELL.XCLL's own per-cell authored ambient color, layered on top of the
## shared INTERIOR_ENVIRONMENT.tres baseline (energy/tonemap/SDFGI/SSAO/etc
## all stay exactly as hand-tuned there -- only ambient_light_color is
## overridden). Duplicates the base resource per load rather than mutating
## INTERIOR_ENVIRONMENT itself, which stays the shared, editor-tunable
## fallback for any cell with no XCLL (a real, common case -- e.g. exterior
## cells, or an interior cell whose designer never touched the lighting tab)
## -- get_cell_lighting_data() returns {} for those, and this just leaves
## INTERIOR_ENVIRONMENT itself assigned, same as before this feature existed.
## Only called for interior (CellLoader) loads -- WorldStreamer's exterior
## cells use EXTERIOR_ENVIRONMENT's own flat sky-driven lighting instead.
func _apply_cell_lighting(cell_form_id: int) -> void:
	if _world_environment == null or cell_loader == null:
		return
	var lighting: Dictionary = cell_loader.esm.get_cell_lighting_data(cell_form_id)
	if lighting.is_empty():
		return
	var env: Environment = INTERIOR_ENVIRONMENT.duplicate()
	env.ambient_light_color = lighting["ambient_color"]
	_world_environment.environment = env

## Debug HUD: current cell's own EditorID, plus its worldspace grid
## coordinate when it's an exterior cell (get_exterior_cell_grid() returns
## {} for interior cells -- a real, valid case, not an error, per its own
## doc comment in esm_reader_gd.h).
func _update_cell_hud(cell_form_id: int) -> void:
	if _cell_label == null:
		return
	_hud_cell_form_id = cell_form_id
	var editor_id: String = cell_loader.esm.get_cell_editor_id(cell_form_id)
	var label: String = editor_id if editor_id != "" else "0x%X" % cell_form_id
	var grid: Dictionary = cell_loader.esm.get_exterior_cell_grid(cell_form_id)
	if not grid.is_empty():
		label += " (%d, %d)" % [int(grid["x"]), int(grid["y"])]
	_cell_label.text = "cell: " + label

## Converts a raw XTEL destination into Godot world space for an EXTERIOR
## landing cell -- unlike _convert_dest_spawn_transform() below, there's no
## single tile RefrRoot to convert through here (WorldStreamer may have
## several, or none yet, resident). Exterior REFR positions are already
## absolute world coordinates (confirmed: cell_loader.gd's own terrain
## placement never applies a per-tile offset to REFR positions, only to the
## LAND heightmap), so this only needs the same fixed Z-up -> Y-up axis
## conversion every RefrRoot/tile root already applies at position zero --
## identical math to what `refr_root.global_transform * local_pos` would
## produce for a root at the origin, just without needing an actual node.
func _convert_dest_spawn_transform_exterior(local_pos: Vector3, local_rot: Vector3) -> Dictionary:
	var axis_basis := Basis(Vector3.RIGHT, deg_to_rad(-90))
	var world_pos: Vector3 = axis_basis * local_pos
	var world_basis: Basis = axis_basis * GamebryoMeshResolver.refr_basis(local_rot)
	var world_rot := Vector3(0, world_basis.get_euler().y, 0)
	return { "position": world_pos, "rotation": world_rot }

## Converts a raw XTEL destination (same ESM-local convention as any REFR's
## DATA position/rotation) into Godot world space via the newly-loaded
## cell's own real RefrRoot transform -- identical math to
## _find_coc_spawn_transform() below, just fed a door's destination instead
## of a marker's.
func _convert_dest_spawn_transform(local_pos: Vector3, local_rot: Vector3) -> Dictionary:
	if cell_loader == null or cell_loader._current == null:
		return {}
	var refr_root: Node3D = cell_loader._current.get_node("RefrRoot")
	var world_pos: Vector3 = refr_root.global_transform * local_pos
	var world_basis: Basis = refr_root.global_transform.basis * GamebryoMeshResolver.refr_basis(local_rot)
	var world_rot := Vector3(0, world_basis.get_euler().y, 0)
	return { "position": world_pos, "rotation": world_rot }

## Bethesda's own "Center On Cell" reference marker — a real, per-cell REFR
## (base_editor_id "COCMarkerHeading", model MarkerCOCHeading.nif),
## confirmed present in GSDocMitchellHouse with a sensible in-room position.
## Its position/rotation are in the same local Bethesda Z-up space as every
## other REFR — converted to actual Godot world space via RefrRoot's own
## real transform (the same one every placed object in the cell already
## goes through), not by re-deriving the Z-up -> Y-up rotation math by hand.
func _find_coc_spawn_transform() -> Dictionary:
	if cell_loader == null or cell_loader._current == null:
		return {}
	var marker: Dictionary = cell_loader.find_ref_by_editor_id("COCMarkerHeading")
	if marker.is_empty():
		return {}
	var refr_root: Node3D = cell_loader._current.get_node("RefrRoot")
	var local_pos: Vector3 = marker.get("position", Vector3.ZERO)
	var local_rot: Vector3 = marker.get("rotation", Vector3.ZERO)
	var world_pos: Vector3 = refr_root.global_transform * local_pos
	var world_basis: Basis = refr_root.global_transform.basis * GamebryoMeshResolver.refr_basis(local_rot)
	var world_rot := Vector3(0, world_basis.get_euler().y, 0) # yaw only -- matches a first-person controller's own convention
	return { "position": world_pos, "rotation": world_rot }

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
	var player := _find_character_body(self)
	if player == null:
		push_warning("game.gd: no CharacterBody3D found to reposition")
		return
	player.global_position = pos
	if "HEAD" in player and player.HEAD != null:
		player.HEAD.rotation.y = rot.y
	else:
		player.rotation = rot # fallback for a non-FPC CharacterBody3D
	if "velocity" in player:
		player.velocity = Vector3.ZERO

func _find_character_body(node: Node) -> CharacterBody3D:
	if node is CharacterBody3D:
		return node
	for c in node.get_children():
		var found := _find_character_body(c)
		if found != null:
			return found
	return null

## Returns the currently-loaded cell's combined world-space AABB (from its
## MeshInstance3D descendants), or null if nothing is loaded / has no
## geometry.
func _current_cell_aabb() -> Variant:
	if cell_loader == null or cell_loader._current == null:
		return null
	var combined := AABB()
	var have := false
	for mi in _mesh_instances(cell_loader._current):
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
