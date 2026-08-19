extends Node3D

## The real runtime entry point — not a @tool inspection scene
## (interior_viewer.gd/exterior_viewer.gd) and not a headless test. Loads
## the game's actual default starting cell (GSDocMitchellHouse, the same
## default used throughout Phase 1/2) via CellLoader on startup.
##
## This is where a player controller belongs. Add it as a sibling of
## CellLoader in this scene. CellLoader deliberately has no idea a player
## exists (phases/2/07-runtime-cell-loader.md) — your controller's own
## interaction code calls DoorNode.activate() on a raycast hit, then
## CellLoader.load_cell(dest_cell_form_id), then repositions itself to
## dest_position/dest_rotation once load_completed fires. See
## _on_load_completed() below for where that wiring goes.
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

var cell_loader: CellLoader

func _ready() -> void:
	cell_loader = $CellLoader # a real scene-tree node now (see game.tscn), not code-instantiated
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
		return

	# Door transitions (not this scene's own startup load) should call
	# reposition_player() directly with the real XTEL-resolved landing
	# transform from DoorNode.activate() instead of relying on this
	# COCMarkerHeading/AABB fallback — see the class doc comment above.
	var spawn := _find_coc_spawn_transform()
	if spawn.is_empty():
		spawn = _find_fallback_spawn_transform()
	if not spawn.is_empty():
		reposition_player(spawn["position"], spawn["rotation"])

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
## new cell. `rotation` is Euler radians (Y = facing/yaw is what actually
## matters for a first-person controller; X/Z are normally left at 0).
func reposition_player(pos: Vector3, rot: Vector3) -> void:
	var player := _find_character_body(self)
	if player == null:
		push_warning("game.gd: no CharacterBody3D found to reposition")
		return
	player.global_position = pos
	player.rotation = rot
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
