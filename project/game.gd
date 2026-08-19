extends Node3D

## The real runtime entry point — not a @tool inspection scene
## (interior_viewer.gd/exterior_viewer.gd) and not a headless test. Loads
## the game's actual default starting cell (GSDocMitchellHouse, the same
## default used throughout Phase 1/2) via CellLoader on startup.
##
## The player controller ("Character", the FPC addon) is a sibling of
## CellLoader in this scene. CellLoader deliberately has no idea a player
## exists (phases/2/07-runtime-cell-loader.md) — _process() below owns the
## interact raycast instead: on a hit against anything exposing
## activate() -> Dictionary (DoorNode today; any future interactable type
## needs only that same contract, not a change here), it calls
## CellLoader.load_cell(dest_cell_form_id) and repositions the player to
## dest_position/dest_rotation once load_completed fires. See
## _try_interact()/_on_load_completed() below for that wiring.
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

const DEFAULT_CELL_EDITOR_ID := "GSProspectorSaloonInterior"

# Interact reach: no game-data source for this (it's a pure UX/feel
# constant in the original engine too, not derived from anything in the
# ESM/NIF data) -- picked to comfortably reach a door/lever from just
# outside its collision, not tuned further.
const INTERACT_REACH_METERS := 2.5

var cell_loader: CellLoader
var _cell_label: Label

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
	_cell_label = $DebugHud/CellLabel
	cell_loader.load_started.connect(_on_load_started)
	cell_loader.load_completed.connect(_on_load_completed)
	await get_tree().process_frame # let CellLoader's own _ready() open the ESM

	# Reuse CellLoader's already-open EsmReader rather than opening a second one.
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
	if cell_loader == null or cell_loader._loading:
		return # a load is already in flight -- don't stack another
	if Input.is_action_just_pressed("interact"):
		_try_interact()

func _try_interact() -> void:
	var player := _find_character_body(self)
	if player == null or not ("CAMERA" in player) or player.CAMERA == null:
		return
	var camera: Camera3D = player.CAMERA
	var from: Vector3 = camera.global_position
	var to: Vector3 = from - camera.global_transform.basis.z * INTERACT_REACH_METERS
	var query := PhysicsRayQueryParameters3D.create(from, to)
	var result: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	if result.is_empty():
		return
	var collider: Object = result.get("collider")
	if collider == null or not collider.has_method("activate"):
		return
	var outcome: Dictionary = collider.activate()
	if outcome.is_empty():
		return # a valid interactable with nothing to do right now (e.g. a non-teleporting door)
	_pending_door_spawn = { "position": outcome["dest_position"], "rotation": outcome["dest_rotation"] }
	cell_loader.load_cell(int(outcome["dest_cell_form_id"]))

## Debug HUD: current cell's own EditorID, plus its worldspace grid
## coordinate when it's an exterior cell (get_exterior_cell_grid() returns
## {} for interior cells -- a real, valid case, not an error, per its own
## doc comment in esm_reader_gd.h).
func _update_cell_hud(cell_form_id: int) -> void:
	if _cell_label == null:
		return
	var editor_id: String = cell_loader.esm.get_cell_editor_id(cell_form_id)
	var label: String = editor_id if editor_id != "" else "0x%X" % cell_form_id
	var grid: Dictionary = cell_loader.esm.get_exterior_cell_grid(cell_form_id)
	if not grid.is_empty():
		label += " (%d, %d)" % [int(grid["x"]), int(grid["y"])]
	_cell_label.text = "cell: " + label

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
