class_name CellStreamBuilder
extends RefCounted

## phases/2/08-world-cell-streaming.md: the actual "given esm/resolver/
## registry instances, stream one cell's terrain+REFRs across frames" work,
## extracted out of CellLoader.load_cell()'s inline loop so it isn't
## duplicated between CellLoader's single-active-cell path and
## WorldStreamer's continuous multi-tile streaming. Owns no tree state of
## its own (no parent, no generation counter) -- callers own the target
## Node3D and their own cancellation/generation bookkeeping, passed in via
## Callables, so this stays reusable by both.

signal progress(fraction: float)

const CELL_SIZE_UNITS := 4096.0
const GAMEBRYO_UNITS_TO_METERS := 1.0 / 70.0

var esm: EsmReader
var resolver: GamebryoMeshResolver
var registry: GamebryoObjectRegistry
var objects_per_frame: int

func _init(esm_reader: EsmReader, mesh_resolver: GamebryoMeshResolver, object_registry: GamebryoObjectRegistry, refs_per_frame: int = 20) -> void:
	esm = esm_reader
	resolver = mesh_resolver
	registry = object_registry
	objects_per_frame = refs_per_frame

## Builds a terrain mesh for `cell_form_id`, positioned at its own
## worldspace grid offset -- null (no terrain) for an interior cell or an
## exterior cell with no LAND, a real valid case, not an error. Not parented
## to anything -- the caller decides where/how to add it (and whether to
## apply editor ownership).
func build_terrain(cell_form_id: int) -> Node3D:
	var land: Dictionary = esm.get_land_data(cell_form_id)
	if land.is_empty():
		return null
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
	return terrain

## Streams `refs` (already-resolved REFR placement Dictionaries -- the
## caller decides what set: a single cell's own, plus a worldspace's
## persistent refs, or a persistent-only set for a dedicated PersistentRoot)
## into `parent`, batching `objects_per_frame` before yielding a frame.
## `add_child_fn.call(parent, node)` lets the caller decide add-child
## semantics (e.g. CellLoader's own editor-ownership step) without this
## class knowing about the editor at all. `is_cancelled.call()` is checked
## after every yield; returns false the moment it reports true (caller
## should discard whatever was partially built, same as CellLoader's own
## generation-counter pattern), true once every ref has been placed.
##
## `batch` (phases/2/09-direct-server-static-geometry.md, optional, default
## null): when given, each placement first tries
## registry.build_direct(p, batch) -- the RID-based path, no Node at all --
## before falling back to registry.build() (a real Node) if that returns
## false (an interactive/registered type, a marker, or genuinely nothing to
## place). null preserves the original all-Node behavior unchanged --
## CellLoader passes null deliberately (its @tool editor-preview mode stays
## fully Node-based/Scene-dock-inspectable, per that task's own scope
## decision), only WorldStreamer passes a real batch.
func stream_refs(parent: Node3D, refs: Array, add_child_fn: Callable, is_cancelled: Callable, batch: DirectGeometryBatch = null) -> bool:
	var placed := 0
	var placed_since_yield := 0
	for p in refs:
		var built_direct: bool = batch != null and registry.build_direct(p, batch)
		if not built_direct:
			var node := registry.build(p)
			if node != null:
				add_child_fn.call(parent, node)
				placed += 1
		else:
			placed += 1
		placed_since_yield += 1
		if objects_per_frame > 0 and placed_since_yield >= objects_per_frame:
			placed_since_yield = 0
			progress.emit(float(placed) / float(max(refs.size(), 1)))
			await parent.get_tree().process_frame
			if is_cancelled.call():
				return false
	return true

## Recursively enables/disables every CollisionShape3D under `node` -- used
## to keep a half-built subtree physically inert until it's fully streamed
## in and swapped/merged into place.
static func set_collision_disabled(node: Node, disabled: bool) -> void:
	if node is CollisionShape3D:
		node.disabled = disabled
	for c in node.get_children():
		set_collision_disabled(c, disabled)
