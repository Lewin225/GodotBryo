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
## Only caller left is CellLoader's own single-active-cell/editor-preview
## path (its @tool mode stays fully Node-based/Scene-dock-inspectable, per
## phases/2/09's own scope decision) -- WorldStreamer's continuous
## multi-tile streaming moved to phases/2/10-threaded-streaming-workers.md's
## resolve_tile()/construct_from_resolved() split instead (checked out a
## resolver context, resolved on a WorkerThreadPool task, committed on the
## main thread), which is also why this no longer takes a DirectGeometryBatch
## parameter -- WorldStreamer was the only caller that ever passed one.
func stream_refs(parent: Node3D, refs: Array, add_child_fn: Callable, is_cancelled: Callable) -> bool:
	var placed := 0
	var placed_since_yield := 0
	for p in refs:
		var node := registry.build(p)
		if node != null:
			add_child_fn.call(parent, node)
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
