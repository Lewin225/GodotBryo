# 2.9 — Direct RenderingServer/PhysicsServer3D Geometry (kill per-node overhead)

Parent: [Phase 2](README.md)

Checkpoint before starting: git tag `pre-direct-server-geometry` (at `eee5af3`) — revert target if
this goes wrong, `git diff pre-direct-server-geometry` to review the full change once done.

## Goal

Rendering-issues list #2/#5 (poor, flat exterior FPS; visible streaming stalls). Confirmed via a
real, controlled headless measurement in Goodsprings (not guessed): `process_frame` wall time
~31.85ms (matches the observed ~30fps almost exactly) vs. `physics_frame` wall time ~16.6ms (just
the normal 60Hz tick, not evidence of expensive physics). Measured **headless**, where no real GPU
rendering happens at all — ruling out both vsync (independently confirmed: interior jumps to
1500+fps with vsync off, exterior stays pinned at ~30 regardless) and raw GPU/shader cost. That
leaves CPU-side per-node engine overhead scaling with sheer node count: 14,258 total nodes, 2,301
active `CollisionShape3D`s, ~7,711 "objects" for one resident 3×3 tile ring + the persistent cell.

Every placed object — interactive or not — currently gets a real Godot Node subtree
(`GamebryoReference extends StaticBody3D`, with `MeshInstance3D`/`CollisionShape3D` children).
Godot pays real per-frame CPU cost per node (transform propagation, AABB/visibility computation,
physics-body sync) regardless of whether that node ever needs to be individually addressable.

## What's already true, that this reuses rather than reinvents

- `GamebryoMeshResolver` (2.0) already deduplicates at the **resource** level — the same model
  path's parsed mesh/decoded textures/built material are one shared `Resource` (and therefore one
  shared RID) across every placement. Confirmed via the debug overlay's own cache-hit numbers.
  What's *not* shared today is the **node**: `populate_mesh_children()`/`populate_collision_children()`
  deliberately build a fresh `MeshInstance3D`/`CollisionShape3D` per placement (position/parenting
  isn't shareable) — this task doesn't change that resource-level sharing at all, it changes what
  wraps it.
- `GamebryoObjectRegistry.build()` **already** cleanly separates interactive types (DOOR → `DoorNode`,
  CONT → `ContainerNode`, ACTI → `ActivatorNode`, FURN → `FurnitureNode`, LIGH → `LightNode`) from
  the plain structural fallback (`GamebryoVisual`, confirmed the overwhelming majority of real
  placements — 360/428 in `GSDocMitchellHouse` alone, and effectively everything in the persistent
  cell dump). This is exactly the split this task needs: only the registered interactive types have
  any reason to be addressable Nodes with `activate()`/script behavior at all.

## Confirmed API surface (checked against real Godot 4.x docs, not assumed)

- `RenderingServer.instance_create2(mesh_rid, scenario_rid)` — one call creates a renderable
  instance with no Node, tied directly to a `World3D`'s scenario.
- `RenderingServer.instance_set_transform(instance, transform)` / `instance_set_visible()` /
  `instance_set_layer_mask()` — per-instance configuration, all RID-addressed.
- `RenderingServer.free_rid(rid)` — explicit free (no automatic GC/refcounting for server-side
  instances the way Node.free() works).
- `PhysicsServer3D.body_create()` + `body_set_mode(BODY_MODE_STATIC)` + `body_set_space(space_rid)`
  + `body_add_shape(body, shape_rid, transform)` + `body_set_shape_transform()` — a real static
  collider, no `StaticBody3D`/`CollisionShape3D` pair needed.
- **Open, deliberately not investigated further**: `body_attach_object_instance_id()`'s exact
  behavior for a bare non-Node `Object` and whether `PhysicsDirectSpaceState3D.intersect_ray()`'s
  `collider` key resolves the same way for it as for a real `CollisionObject3D`. Doesn't block this
  task — interactive types (the only ones that need a raycast-resolvable `collider`) are explicitly
  staying as real Nodes; this only matters if a future task wants raycast-addressable direct-server
  geometry too.

## The real tradeoff: editor Scene-dock inspectability

RID-based instances/bodies have no Node, so they never appear in the editor's Scene dock — you
can't click one to inspect it. `CellLoader`'s own `@tool` editor-preview mode (2.7) exists
specifically so a cell can be dropped in and inspected without pressing Play; losing per-object
inspectability there would undercut that. Resolved by scope, not by accepting the loss:
`CellLoader` (editor-preview, single-cell) keeps building real Nodes exactly as it does today —
its own scale (one cell, not nine tiles + a persistent cell) was never the performance problem in
the first place. Only `WorldStreamer`'s continuous runtime multi-tile streaming path adopts direct
RIDs for the non-interactive fallback case. The two are already separate classes (2.8), so this
falls out of the existing split rather than needing a new one.

## Step-by-step implementation TODO

1. **`DirectGeometryBatch`** (new, small, owns no Node) — a plain class tracking parallel arrays of
   rendering-instance RIDs and physics-body RIDs for one resident tile's worth of non-interactive
   geometry. Methods: `add(mesh_rid, shape_rids, transform)` (issues the actual
   `instance_create2()`/`body_create()` calls), `set_enabled(bool)` (space attach/detach for
   physics — the RID equivalent of today's `_set_collision_disabled()`/hidden-until-swapped-in
   pattern — plus `instance_set_visible()` for rendering), `free_all()` (the RID equivalent of
   `Node.free()` — must be explicit, nothing frees these automatically).
2. **A direct-build path in (or alongside) `GamebryoObjectRegistry`** — e.g.
   `build_direct(placement, resolver, batch: DirectGeometryBatch) -> bool`, used only for
   placements that fall through to the generic `GamebryoVisual` structural fallback (i.e., no
   registered factory for that `base_type`). Reuses the resolver's already-cached `Mesh`/`Shape3D`
   resources' `.get_rid()` — no new asset/parsing work, this is purely a different way of
   presenting data already being built today.
3. **`WorldStreamer` per-tile bookkeeping split**: each resident tile keeps its existing terrain +
   interactive-object Node subtree (unchanged — terrain and DOOR/CONT/ACTI/FURN/LIGH stay exactly
   as they are) *plus* a `DirectGeometryBatch` for everything else. `_stream_tile()`'s placement
   loop dispatches per-placement: registered type → `registry.build()` (Node, as today); otherwise
   → `build_direct()` (RID, new). Same split applies to the `PersistentRoot` build.
4. **Streaming-safety semantics**: today's "hidden + collision-disabled until fully streamed in,
   then flipped on atomically" pattern must hold for RID batches too — `DirectGeometryBatch`'s
   `set_enabled(false)` during streaming, `set_enabled(true)` at the same moment the tile's Node
   subtree gets its own visibility/collision flip.
5. **Teardown**: tile/`PersistentRoot` unload frees both the Node subtree (as today) and calls
   `DirectGeometryBatch.free_all()` — must happen together, in the same unload path, so a batch
   never outlives (or gets orphaned from) the tile it belongs to.
6. **`CellLoader` stays untouched** — no direct-RID path, per the tradeoff section above. Verify
   this explicitly (its own test suite should need zero changes) rather than assuming the split
   held.
7. **`DebugStats.gd`**: add RID-instance/body counts alongside the existing Node count, so the
   actual reduction is visible in the F3 overlay, not just inferred.
8. **Re-measure**: same headless probe methodology used to find this problem (`process_frame`/
   `physics_frame` wall-clock timing in a real streamed Goodsprings scene) — confirm both the node
   count and the frame-time cost actually drop, not just that it builds without erroring.

## Deliverables

- `DirectGeometryBatch`: RID-tracking for one tile's non-interactive geometry, no Node involved.
- `GamebryoObjectRegistry`'s (or a sibling's) direct-build path for the structural-fallback case.
- `WorldStreamer` (not `CellLoader`) building/streaming/tearing down both Node subtrees (unchanged,
  interactive-only) and RID batches (new, everything else) per resident tile and the persistent
  root.
- `DebugStats.gd` reporting RID counts alongside Node count.

## Acceptance criteria

- [ ] Headless re-measurement in a real streamed Goodsprings scene shows both total node count and
      `process_frame` wall-clock time drop substantially from the pre-refactor baseline (14,258
      nodes / ~31.85ms), not just "it looks faster."
- [ ] Doors/containers/activators/furniture/lights still work identically (existing
      `test_door_activate.gd`/`test_object_registry.gd`/`test_cell_loader.gd` suites pass
      unmodified) — confirms the interactive/non-interactive split didn't regress the objects that
      must stay real Nodes.
- [ ] `CellLoader`'s own test suite and `@tool` editor-preview behavior need zero changes —
      confirms the tradeoff was actually resolved by scope, not silently reintroduced.
- [ ] A resident tile's direct-geometry batch is correctly hidden/enabled in lockstep with its
      Node subtree during streaming (no visible/collidable-too-early half-built state) and freed
      exactly once on unload (no leaked RIDs, no double-free) — verified directly, not assumed
      from the Node-based pattern already working.
- [ ] A real visual playtest in Goodsprings confirms no missing geometry and a genuinely improved,
      stable frame rate — the actual point of this task, not just the headless numbers.
