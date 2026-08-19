# 2.10 — Threaded Tile Resolve (WorkerThreadPool)

Parent: [Phase 2](README.md)

Checkpoint before starting: git tag `pre-threaded-streaming` (at `5ee8167`) — revert target if
this goes wrong, `git diff pre-threaded-streaming` to review the full change once done.

## Goal

Task 2.2's own unfinished deliverable ("Threading investigation concludes with either a
verified-safe implementation or an explicit documented deferral") plus rendering-issues #5
(streaming stalls, folded-in mouse-snap-during-load symptom) — now with a real measured budget to
build against, not a guess.

Confirmed via a real, controlled headless measurement (not guessed): a 30s scripted camera walk
through Goodsprings, driven through the real `WorldStreamer`, avg frame time 7.71ms (fine) but
**1% low 75.11ms (~13.3fps)** and a recurring spike pattern — frame time jumps to 30-40ms almost
exactly every ~0.5s (matches `WorldStreamer.CHECK_INTERVAL_SEC` exactly), with roughly every 5th
spike much worse (146-149ms). This is the mechanism behind the user's real-play "mouse snap"
report: not continuous stutter, a real spike every time `_check_streaming()` starts a new tile
load, which is constantly while walking. One further one-time 787ms spike at `activate()` itself
(the `PersistentRoot` build) is a separate, one-shot cost, not the repeating stutter.

Root cause: `CellStreamBuilder.stream_refs()`'s per-frame batch (`objects_per_frame` placements'
worth of BSA extract / NIF parse / mesh build / texture decode / `RenderingServer`+
`PhysicsServer3D` calls) still runs entirely synchronously on the main thread, all at once, inside
one frame, every time a batch is due. Yielding a frame between batches (the existing pattern) only
spreads *how often* this happens — it does nothing about how expensive each batch itself is.

**Explicit prioritization for this task** (user direction): get real parallelism across available
cores working first, before spending time hand-tuning `objects_per_frame`/batch-size-for-frame-time
— this machine has 16 cores and up to 9 tiles resident at once (`RADIUS_LOAD=1`, 3×3), which is
real headroom sitting unused today. Batch-size tuning against the 16.6ms budget is still worth
doing afterward (not in scope here) but shouldn't be the first lever pulled.

## What's already true, that this reuses rather than reinvents

- `GamebryoMeshResolver.get_direct_geometry_entries()` (2.9) already separates "resolve a
  placement's NIF/mesh/texture/collision data" from "do something with it" — it returns plain data
  (`{ "mesh_entries": [...], "shape_entries": [...] }`), no Node, no RID calls. This task extends
  that same resolve/build split to the interactive-type factories too
  (`populate_mesh_children()`/`populate_collision_children()` currently do resolve-and-build-Node
  in one step) rather than inventing a new pattern.
- `WorldStreamer` already streams per-tile, one `_stream_tile()` call per resident coordinate, plus
  one `_stream_persistent_root()` call — the natural task-granularity boundary already exists in
  the code, nothing new needs inventing there.
- `DirectGeometryBatch` (2.9) already defers all `RenderingServer`/`PhysicsServer3D` calls to an
  explicit `build()` step, separate from data accumulation — exactly the "accumulate off-thread,
  commit on the main thread" shape this task needs, just not populated by a worker yet.

## Confirmed thread-safety findings (checked directly against this codebase and real Godot docs,
## not assumed)

- `RenderingServer`/`PhysicsServer3D` are **not** thread-safe by default (confirmed against Godot's
  own Thread-Safe APIs docs) — calling their methods requires the `Rendering > Driver > Thread
  Model: Separate` / `Physics > 3D > Run on Separate Thread` project settings, and the docs flag the
  rendering one as having known bugs. **Decision: don't enable either.** All RS/PS3D calls
  (`DirectGeometryBatch.add_object()`/`build()`/`set_enabled()`, and any future Node creation) stay
  main-thread-only, unchanged from today.
- Godot Resource creation/manipulation off the main thread (new `ArrayMesh`, `ImageTexture.
  create_from_image()`) **is** documented safe, with the caveat "don't load the same resource from
  multiple threads at once" — this is exactly why per-task-private reader/cache state (below)
  matters, not shared ones.
- `BsaArchive` and `EsmFile` are each already commented at the source as "Not thread-safe (single
  `FILE*` with seek+read)" — this was already known, not a new finding. `GamebryoMeshResolver`
  currently caches and **reuses one shared reader instance per archive** across the whole session
  (`_bsa_readers`) — that reuse pattern is exactly what would break under concurrent tile tasks and
  must not be shared unmodified.
- `nif::load_mesh(bytes)` (the C++ NIF parser) operates purely on an in-memory buffer, no file
  handle, no shared mutable state — confirmed by reading `nif_loader.h`/`.cpp` directly. Safe to
  call concurrently on different buffers from different threads. The only shared state in the parse
  path is nifly's `NiFactoryRegister::Get()` Meyer's singleton (`native/nifly/src/Factory.cpp`),
  populated once in its constructor (C++11 guarantees thread-safe lazy init) and read-only
  afterward — confirmed by reading the source, not assumed safe.
- GDScript Dictionaries (the resolver's `_nif_cache`/`_mesh_cache`/`_texture_cache`/
  `_material_cache`) need mutex protection for concurrent *writes* per Godot's own docs — sidestepped
  entirely by design here (see below), not solved with a `Mutex`.

## Design: resolve on workers, commit on main — no mutex anywhere

Rather than share caches/readers across threads (and need locking), give each concurrent tile task
its own private resolver state, and make the main thread the only writer to anything shared:

1. **A small pool of `GamebryoMeshResolver` instances**, sized to the worker pool's thread count —
   each with its own private `_bsa_readers`/`_nif_cache`/etc., checked out to a tile's worker task
   and back in when it completes. No two threads ever touch the same reader instance concurrently;
   archive handles still get reused across tiles assigned to the same pool slot (not reopened per
   tile).
2. **One `WorkerThreadPool.add_task()` per tile** (and one for the persistent root) — matches
   `_stream_tile()`'s existing granularity. The task does, for every placement in that tile: resolve
   NIF (via its checked-out resolver instance), build the `ArrayMesh`/decode textures/build collision
   descriptors, and return **plain data only** — no RS/PS3D calls, no Node creation, no writes to any
   *shared* cache (writes go to the task's own private resolver instance, merged on commit).
3. **Main thread polls** (`WorkerThreadPool.is_task_completed()`, checked in the same per-frame spot
   the current yield loop lives) and, once a tile's task is done:
   - merges the task's private resolver caches into the shared ones (single-threaded, so this needs
     no `Mutex` — only the main thread ever writes the shared caches)
   - feeds structural-fallback results into `DirectGeometryBatch` (as today)
   - builds the real Node tree for interactive types from the already-resolved data (cheap now — no
     I/O left in this step, just `Node.new()` + property assignment)
   - same atomic visible/enabled flip as today

## Step-by-step implementation TODO

1. **Split resolve from construct in `GamebryoMeshResolver`** for the interactive-type path, the
   same way 2.9 already did for the structural-fallback path: extend
   `get_direct_geometry_entries()`'s shape (or add a sibling) so `populate_mesh_children()`/
   `populate_collision_children()` become thin wrappers that build Nodes from already-resolved data,
   with the actual resolve work callable standalone (no Node touched at all). Verify via the
   existing `test_object_registry.gd` suite (should need no behavior changes, only an internal
   reshape) before moving on.
2. **`GamebryoMeshResolver` "instance pool"**: a small new class (or a plain `Array` the caller
   manages) holding N independently-constructed `GamebryoMeshResolver`s (N = a sane worker count,
   not necessarily `OS.get_processor_count()` verbatim — pick a starting value, measure, adjust).
   Checkout/checkin semantics simple enough not to need their own locking (a tile task claims one
   before `add_task()`, returns it when its data is fully returned to the main thread — the checkout
   itself happens on the main thread, so this is safe without a `Mutex` too).
3. **Per-tile resolve task**: a function taking a checked-out resolver instance + a tile's ref list,
   doing the resolve-only work from step 1 for every placement, returning one Dictionary/Array of
   fully-resolved per-placement data (geometry, and enough metadata — door destinations, light data,
   marker kind — for step 4 to build the right Node type without re-touching the ESM). Wrapped via
   `WorkerThreadPool.add_task()`.
4. **`WorldStreamer` commit step**: replace `_stream_tile()`'s current synchronous
   `_builder.stream_refs()` call with: kick off the worker task, poll each frame
   (`is_task_completed()`) instead of `await parent.get_tree().process_frame` on a GDScript batch
   loop, and once complete, do the (now cheap, main-thread-only) construct step — Node creation for
   interactive types, `DirectGeometryBatch.add_object()` for the rest — plus the cache-merge from the
   task's private resolver back into the shared one. Same treatment for `_stream_persistent_root()`.
5. **Cancellation**: today's generation-counter pattern (`my_generation != _generation`) already
   handles a tile being superseded mid-stream. Extended meaning under threading: if a tile is
   cancelled while its worker task is still running, the task must still be allowed to finish (no
   safe way to kill a running `WorkerThreadPool` task) — its resolver instance stays checked out
   until then, and its result is simply discarded (not committed) on the next poll once the
   generation check fails, exactly mirroring the existing discard-on-cancel path but for the
   commit step instead of the batch loop.
6. **`DebugStats.gd`**: surface in-flight worker task count and resolver-pool utilization (how many
   of N instances are currently checked out) alongside the existing RID/Node counts — needed to see
   whether the pool is actually being saturated, not just trusted to be.
7. **Re-measure**: same headless benchmark methodology from this task's own budget-measurement step
   (scripted camera walk through Goodsprings, `Time.get_ticks_usec()` per-frame deltas, 1% low +
   spike-frequency reporting) — confirm the ~0.5s-periodic 30-40ms spikes shrink or disappear, not
   just that streaming still works. Keep the benchmark script itself out of the committed project
   tree (scratch, like the one used to establish the budget) unless it's worth keeping as a
   permanent regression tool — decide explicitly, don't leave it half-committed.

## Deliverables

- `GamebryoMeshResolver`'s interactive-type factories resolve-then-construct, same shape 2.9 already
  gave the structural-fallback path.
- A small resolver-instance pool, checkout/checkin managed on the main thread only.
- `WorldStreamer` tile/persistent-root streaming driven by `WorkerThreadPool` tasks instead of a
  synchronous per-frame GDScript batch loop, with cache merges and all RS/PS3D/Node work still
  strictly main-thread-only.
- `DebugStats.gd` reporting in-flight task count + pool utilization.

## Acceptance criteria

- [ ] Headless re-measurement (same walk-through-Goodsprings methodology used to establish the
      75.11ms 1%-low budget) shows the ~0.5s-periodic spike pattern substantially reduced — a
      stated before/after 1% low and spike-frequency comparison, not just "feels smoother."
- [ ] No shared mutable state is ever written from more than one thread — verified by construction
      (resolver-pool checkout discipline, all RS/PS3D/Node/shared-cache writes traced to the main
      thread) and spot-checked, not just assumed from the design doc.
- [ ] Doors/containers/activators/furniture/lights still work identically (existing
      `test_door_activate.gd`/`test_object_registry.gd`/`test_cell_loader.gd` suites pass
      unmodified).
- [ ] Cancellation (moving away before a tile's worker task finishes) doesn't crash, leak the
      checked-out resolver instance, or commit a superseded tile's geometry — verified directly
      (a real cancel-mid-stream repro), not assumed safe from the generation-counter pattern alone.
- [ ] `CellLoader`'s own editor-preview path needs zero changes (it doesn't stream via
      `WorldStreamer`/`CellStreamBuilder`'s threaded path at all — confirms scope stayed where 2.9
      already drew the line).
- [ ] A real playtest walk through Goodsprings confirms the mouse-snap/stutter-during-load symptom
      is genuinely improved, not just the headless numbers.
