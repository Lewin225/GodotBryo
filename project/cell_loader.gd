@tool
class_name CellLoader
extends Node3D

## phases/2/07-runtime-cell-loader.md, Step 2. A real cell loader usable
## BOTH ways: as a runtime node a door interaction calls (load_cell()), and
## as an @tool node usable directly in the Godot editor (an exported
## `cell_editor_id` + a "Load Cell" inspector button — same interactive
## pattern interior_viewer.gd/exterior_viewer.gd already established) for
## inspecting a specific cell without needing to press Play.
##
## A real scene-tree node (declared in a .tscn, e.g. game.tscn), not
## something spawned purely via code — LoadingCell/CurrentCell are built as
## its own children either way.
##
## Interior and exterior are NOT separate code paths a caller has to choose
## between — dispatch is entirely internal (see load_cell()'s own comment).
##
## Deliberately narrower than full continuous world streaming (adjacent
## cells loading/unloading as the player walks around — the larger,
## still-unscoped rest of Phase 2's ROADMAP goal). This loads exactly the
## one cell it's asked for, nothing more.
##
## Player repositioning is NOT this class's job. It has no idea a player
## controller exists. A caller (e.g. a door-interaction handler, which
## already has the landing transform from DoorNode.dest_position/
## dest_rotation before ever calling load_cell()) listens for
## load_completed and moves whatever player node it owns itself — keeps
## this class decoupled from a player controller that doesn't exist in
## this codebase yet.
##
## The current (or currently loading) cell's REFR placement data is cached
## as it's fetched — not just built into nodes and forgotten — so a caller
## can query it directly (e.g. look up a specific marker/start REFR by
## EditorID) instead of re-deriving the same data from ESM itself. See
## get_current_refs()/find_ref_by_editor_id()/find_ref_by_form_id() below.
## Available as soon as load_started fires, not only once load_completed
## does — a caller can look up where it's going before the swap finishes.
##
## No retention/cache of the previous cell (deliberately deferred — see
## phases/2/07-runtime-cell-loader.md's discussion: 2.0's resource caching
## already makes a "cold" rebuild of a recently-visited cell cheap, since
## NIF/texture/material work is cached session-wide by resolved path, not
## per-cell; only node instantiation + physics registration repeats. Add a
## small LRU pool later if real measurements say backtracking still isn't
## fast enough, rather than assuming up front.)

signal load_started(cell_form_id: int)
signal load_progress(fraction: float)
signal load_completed(cell_form_id: int, success: bool)

const DATA_DIR := "/var/home/lewin/Desktop/Claude New Vegas Port/fresh_nv_copy/Data/"
const CELL_SIZE_UNITS := 4096.0
const GAMEBRYO_UNITS_TO_METERS := 1.0 / 70.0

## How many REFRs to place per frame before yielding — same frame-budget
## pattern proven in exterior_viewer.gd (phases/2/02).
@export var objects_per_frame: int = 20

## Editor-only convenience: set an EditorID and press "Load Cell" below to
## load it directly in the editor viewport, the same way
## interior_viewer.gd/exterior_viewer.gd already work. Not used at runtime
## — real callers use load_cell(cell_form_id) directly.
@export var cell_editor_id: String = ""
@export_tool_button("Load Cell") var load_button: Callable = _editor_load_cell

var esm: EsmReader
var resolver: GamebryoMeshResolver
var registry: GamebryoObjectRegistry

var _current: Node3D = null # the live "CurrentCell" root, or null before the first load
var _loading := false
var _generation := 0

## The REFR placement Dictionaries (same shape as EsmReader.get_cell_references())
## for the cell currently loading or already loaded — see the class doc
## comment above. Query via get_current_refs()/find_ref_by_editor_id()/
## find_ref_by_form_id() rather than reading this directly.
var _current_refs: Array = []

func _ready() -> void:
	esm = EsmReader.new()
	if not esm.open(DATA_DIR + "FalloutNV.esm"):
		push_error("CellLoader: could not open FalloutNV.esm")
	resolver = GamebryoMeshResolver.new()
	registry = GamebryoObjectRegistry.new(resolver, esm)

func _editor_load_cell() -> void:
	if cell_editor_id == "":
		push_error("CellLoader: cell_editor_id is empty")
		return
	var cell: Dictionary = esm.find_cell_by_editor_id(cell_editor_id)
	if cell.is_empty():
		push_error("CellLoader: cell not found: " + cell_editor_id)
		return
	load_cell(int(cell["form_id"]))

## Returns the REFR placement data for the cell currently loading/loaded —
## see the class doc comment. Copy of the internal array, not a reference
## to it (a new load replaces it wholesale, doesn't mutate in place).
func get_current_refs() -> Array:
	return _current_refs.duplicate()

func find_ref_by_editor_id(editor_id: String) -> Dictionary:
	for p in _current_refs:
		if String(p.get("editor_id", "")) == editor_id:
			return p
	return {}

func find_ref_by_form_id(refr_form_id: int) -> Dictionary:
	for p in _current_refs:
		if int(p.get("refr_form_id", 0)) == refr_form_id:
			return p
	return {}

## Adds `child` under `parent`, and — only when actually running inside the
## editor (Engine.is_editor_hint()) — sets its (and every descendant's)
## owner so it shows up in the Scene dock with a real, savable NodePath,
## same as interior_viewer.gd/exterior_viewer.gd already do. A no-op extra
## step at runtime (is_editor_hint() is false when the game is actually
## playing), so this is safe to always call rather than branching per site.
func _add_child(parent: Node, child: Node) -> void:
	parent.add_child(child)
	if Engine.is_editor_hint():
		_own_recursive(child)

func _own_recursive(node: Node) -> void:
	node.owner = get_tree().edited_scene_root
	for c in node.get_children():
		_own_recursive(c)

## Cancels an in-flight load, if any. The half-built "LoadingCell" is
## discarded; whatever was already the current cell (and, implicitly, the
## player standing in it) is completely untouched — that's the whole point
## of never swapping LoadingCell in until it's fully built.
func cancel_load() -> void:
	if _loading:
		_generation += 1
		_loading = false

## Loads the given CELL (by FormID) as the new current cell, tearing down
## whatever was current before. Interior/exterior dispatch is implicit, not
## a caller decision: every cell is checked for LAND data (get_land_data()
## already returns {} gracefully for an interior cell, or an exterior cell
## that genuinely has none — phases/1/04's own scope note), and terrain is
## only built when LAND data is actually present. get_cell_references() is
## identical either way. No separate "is this interior or exterior" branch
## exists because none is needed.
func load_cell(cell_form_id: int) -> void:
	_generation += 1
	var my_generation := _generation
	_loading = true
	load_started.emit(cell_form_id)

	var loading_root := Node3D.new()
	loading_root.name = "LoadingCell"
	loading_root.visible = false # hidden and physically inert until the swap
	_add_child(self, loading_root)

	var refr_root := Node3D.new()
	refr_root.name = "RefrRoot"
	refr_root.rotation_degrees.x = -90 # NIF/REFR Z-up -> Godot Y-up
	_add_child(loading_root, refr_root)

	var terrain_root := Node3D.new()
	terrain_root.name = "TerrainRoot"
	_add_child(loading_root, terrain_root)

	var land: Dictionary = esm.get_land_data(cell_form_id)
	if not land.is_empty():
		var grid: Dictionary = esm.get_exterior_cell_grid(cell_form_id)
		var grid_x := int(grid.get("x", 0))
		var grid_y := int(grid.get("y", 0))
		var quadrant_ltex: PackedInt64Array = land.get("quadrant_base_ltex", PackedInt64Array())
		var quadrant_textures: Array = []
		for i in range(quadrant_ltex.size()):
			var ltex_id := int(quadrant_ltex[i])
			var tex: Texture2D = null
			if ltex_id != 0:
				var tex_path := esm.resolve_ltex_texture_path(ltex_id)
				if tex_path != "":
					tex = resolver.load_texture("textures\\" + tex_path)
			quadrant_textures.append(tex)
		var terrain := GamebryoTerrainBuilder.build(land, quadrant_textures)
		if terrain != null:
			terrain.position = Vector3(
					grid_x * CELL_SIZE_UNITS * GAMEBRYO_UNITS_TO_METERS,
					0.0,
					-(grid_y * CELL_SIZE_UNITS * GAMEBRYO_UNITS_TO_METERS))
			_set_collision_disabled(terrain, true)
			_add_child(terrain_root, terrain)

	var refs: Array = esm.get_cell_references(cell_form_id)
	# phases/2/07-runtime-cell-loader.md's "Known gap": an exterior cell's
	# owning worldspace has its own "persistent" cell (quest markers,
	# fast-travel triggers, LOD imposters, and every exterior-facing
	# building entrance door — confirmed directly, not assumed) that the
	# real engine always loads alongside whichever grid cell is active. {}
	# for an interior cell (no worldspace) so this is a no-op there.
	refs.append_array(esm.get_persistent_refs_for_cell(cell_form_id))
	_current_refs = refs # queryable immediately, before streaming even starts

	var placed := 0
	var placed_since_yield := 0
	for p in refs:
		var node := registry.build(p)
		if node != null:
			_set_collision_disabled(node, true)
			_add_child(refr_root, node)
			placed += 1
		placed_since_yield += 1
		if objects_per_frame > 0 and placed_since_yield >= objects_per_frame:
			placed_since_yield = 0
			load_progress.emit(float(placed) / float(max(refs.size(), 1)))
			await get_tree().process_frame
			if my_generation != _generation:
				loading_root.queue_free() # superseded/cancelled -- never was "current", safe to defer-free
				return

	if my_generation != _generation:
		loading_root.queue_free()
		return

	# Swap: enable collision + visibility on the now-fully-built cell, then
	# replace whatever was current. The old cell is freed immediately
	# (remove_child + free), not queue_free() -- queue_free()'s deferred
	# removal is exactly the bug already found and fixed once this session
	# in exterior_viewer.gd (a same-named replacement colliding with the
	# not-yet-actually-gone old node and getting silently renamed by Godot).
	_set_collision_disabled(loading_root, false)
	loading_root.visible = true

	# Free the old CurrentCell BEFORE renaming loading_root -- doing it in
	# the other order means the old node is still a sibling actually named
	# "CurrentCell" at the moment of rename, so Godot's own name-collision
	# handling silently renames the new node instead (the exact bug already
	# found and fixed once this session in exterior_viewer.gd, hit again
	# here in the opposite order).
	if _current != null:
		remove_child(_current)
		_current.free()
	loading_root.name = "CurrentCell"
	_current = loading_root

	_loading = false
	load_progress.emit(1.0)
	load_completed.emit(cell_form_id, true)

func _set_collision_disabled(node: Node, disabled: bool) -> void:
	if node is CollisionShape3D:
		node.disabled = disabled
	for c in node.get_children():
		_set_collision_disabled(c, disabled)
