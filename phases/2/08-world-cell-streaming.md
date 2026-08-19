# 2.8 — World Cell Streaming (adjacent-cell load/unload)

Parent: [Phase 2](README.md)

## Goal

Phase 2's own exit criterion: "walk from Goodsprings to Primm without load screens
beyond intended interior transitions, at a stable frame rate." Everything shipped so
far (2.7's `CellLoader`) loads exactly one cell at a time, synchronously replacing
whatever was current — correct for a door transition, but a real exterior worldspace
needs several grid tiles resident around the player simultaneously, loaded and
unloaded continuously as they move, with no single moment where nearby terrain/objects
don't exist yet.

## Not in scope here

- Distant terrain/object LOD (ROADMAP's own separate Phase 2 bullet — this task keeps
  full-detail cells within the streaming radius and nothing beyond it; "what a
  loaded-but-far cell looks like" is a different problem).
- Memory budget / streaming-radius tuning against the real Mojave worldspace size
  (ROADMAP's own separate bullet) — this task picks a starting radius to get the
  mechanism working and correct; real tuning is a follow-on measurement pass, not
  guessed up front.
- Threading the byte-level load work onto `WorkerThreadPool` (2.2's own step 3/4,
  still an open, separately-scoped investigation) — this task reuses 2.2's proven
  frame-yield batching pattern (main-thread, spread across frames), not threading.

## Design corrections made before writing any code (worth recording — the obvious
first design was wrong)

**Streaming trigger is NOT "cross a cell boundary."** A discrete boundary-cross event
means neighboring cells only start loading *after* you've already stepped into the new
tile — for however many frames the load takes, you'd be standing at the edge of a tile
with nothing beyond it, which for a large-enough gap is "see the edge of the loaded
world" and, worse, a real risk of falling through unloaded terrain right at the seam.
Instead: continuously track which cells are within the streaming radius of the current
position and keep that whole set loaded, evaluated every frame (or a cheap throttled
interval) rather than only at boundary-cross instants — cells load in with margin
*before* their edge would ever be visible, not reactively after.

**Track the active camera, not the player body.** `CellLoader`'s own player-agnostic
design (2.7: "CellLoader has no idea a player exists") extends here too — the position
driving streaming must be whatever camera is actually rendering
(`get_viewport().get_camera_3d()`), not a hardcoded reference to the FPC character's
`CAMERA`/body. Hardcoding to the player would silently break free-fly/editor camera
movement (the camera moves, nothing streams in) — an easy mistake to make and a real
one to guard against, not a hypothetical.

## Module boundaries

Four pieces, not one monolithic streamer, so the streaming work doesn't tangle into
`CellLoader`'s existing responsibilities or duplicate them:

- **`CellStreamBuilder`** (new, small, owns no state) — the actual "given `esm`/
  `resolver`/`registry` instances, a target parent `Node3D`, and a cell FormID, stream
  its terrain+REFRs into that parent across frames, cancelable" logic, extracted out of
  `CellLoader.load_cell()`'s inline loop. Dependency-injected, not a singleton — both
  call sites below construct their own instances of `esm`/`resolver`/`registry` and
  pass them in, same self-contained pattern `CellLoader` already uses.
- **`CellLoader`** (existing, mostly unchanged) — still the single-active-cell
  orchestrator (double-buffer swap, `@tool` editor support, interiors and
  door-triggered hard swaps), just delegating its inner build loop to
  `CellStreamBuilder` instead of doing it inline.
- **`WorldStreamer`** (new) — the multi-tile orchestrator: resident-tile bookkeeping
  (grid coordinate → built root), the `PersistentRoot` node's lifecycle, active-camera
  tracking, radius/hysteresis diffing. Owns its own `esm`/`resolver`/`registry`
  (mirroring `CellLoader`'s self-contained pattern rather than sharing instances — a
  second resource cache is a minor, measurable-later inefficiency, not a correctness
  problem, not worth complicating either class's ownership model to avoid pre-emptively).
  Uses `CellStreamBuilder` per resident tile instead of reimplementing the batching.
- **`game.gd`'s door-transition code** (existing, grows two more cases) — the only
  place that knows *why* a transition is happening, matching `CellLoader`'s own
  established "doesn't know why/how the player is here" decoupling. On a door into an
  interior: tear down `WorldStreamer` (`deactivate()`), then `CellLoader.load_cell()`
  as today. On a door out of an interior into an exterior: `WorldStreamer.activate(dest_wrld_form_id)`
  and step back — no "load cell X,Y" command needed, since once active it reacts purely
  to wherever the camera already is (see below).

## Purely position-reactive once active — `WorldStreamer` doesn't know why the player moved

`WorldStreamer` doesn't special-case "just teleported here" vs. "walked one step" — its
per-check diff (desired resident set vs. actual) is the same logic either way, it just
has more entries to stream in on a big jump (a teleport landing somewhere with nothing
currently resident) than on an incremental walk step. No transition-specific code path,
matching the same instinct that keeps `CellLoader` itself ignorant of *why* a cell load
was requested.

This can't be *fully* context-free, though: raw Godot world position alone doesn't
safely imply which worldspace to interpret it against — every interior cell is built at
a fixed local origin regardless of where it conceptually sits in the game world today,
so two unrelated interiors' coordinate spaces (or an interior's and some real exterior
grid tile's) can numerically overlap by coincidence. `WorldStreamer` needs exactly one
piece of explicit state for this: `activate(wrld_form_id)` / `deactivate()`, called once
by whatever's orchestrating a transition (`game.gd`), not derived from position. While
inactive it does nothing at all (correctly dormant while the player's indoors); once
active for a worldspace, everything else — which tiles, hysteresis, the persistent
cell — falls out of the continuous position check with no further input.

**`streaming_settled` signal**, emitted whenever the in-flight tile-load count returns
to zero (having been non-zero) — lets a caller know when it's safe to release the
player/undarken a transition screen without `WorldStreamer` knowing a screen exists.
Fires repeatedly over a session (every walk-triggered tile load settles too, not just
a post-teleport catch-up) — a caller wanting "the initial load after this specific
transition finished" listens for the next occurrence and disconnects, rather than
`WorldStreamer` tracking "is this the first settle" itself.

## What's already available to build on

- `EsmReader.find_exterior_cell(wrld_form_id, x, y)` / `get_exterior_cell_grid(cell_form_id)`
  — coordinate ↔ CELL FormID both ways, already used by 2.7's door-destination
  resolution.
- `cell_loader.gd`'s `CELL_SIZE_UNITS = 4096.0` / `GAMEBRYO_UNITS_TO_METERS = 1/70.0`
  and its terrain placement math (`grid_x * CELL_SIZE_UNITS * GAMEBRYO_UNITS_TO_METERS`,
  Z negated) — the exact conversion needed to go the other way (world position → grid
  coordinate) for streaming's own "which tile is the camera in" check.
- 2.2's proven frame-yield batching pattern (`await get_tree().process_frame` between
  terrain/every `objects_per_frame` REFRs, a generation counter for safe
  cancel-and-restart) — reuse directly, don't re-derive.
- `EsmReader.get_persistent_refs_for_cell()` (2.7's "Known gap" fix) — see the
  duplication problem below, the reason this can't just be called per-tile here the
  way `CellLoader.load_cell()` currently calls it.

## The persistent-cell duplication problem (new, caused by streaming multiple cells at once)

`CellLoader.load_cell()` currently appends `get_persistent_refs_for_cell()`'s result to
*every* single-cell load — harmless when only one cell is ever resident at a time (each
load fully replaces the last), but streaming keeps many grid tiles resident
simultaneously. Calling that same append per-tile would place the worldspace's entire
persistent cell (4,468 refs in `WastelandNV` — quest markers, every exterior building's
own entrance door, ...) once *per currently-loaded tile* — duplicate door/marker nodes
stacked on top of each other, not just wasted work. Fixed by giving persistent refs
their own dedicated node — a single `PersistentRoot` (same `rotation_degrees.x = -90`
axis conversion every tile's own root already applies, position left at zero — exterior
REFR positions, persistent or not, are already absolute world coordinates per
`cell_loader.gd`'s own terrain-placement math, so no per-tile offset is needed or
correct for them anyway), built once via `CellStreamBuilder` when `WorldStreamer`
activates for a worldspace and freed once on `deactivate()` — never tied to any single
grid tile's own load/unload lifecycle, so a per-tile unload can never accidentally touch
it. `find_ref_by_editor_id()`/`find_ref_by_form_id()`-style queries just need to search
across both the per-tile ref lists and `PersistentRoot`'s own — a flat merge, not real
complexity, matching how `CellLoader`'s existing `_current_refs` already works today.

## Steps

1. **Extract per-cell node-building into a shared, reusable piece.** `CellLoader`'s
   `load_cell()` currently builds terrain + REFRs into one hardcoded `LoadingCell`/
   `CurrentCell` pair. The streamer needs the same terrain+REFR building logic, but
   invoked once per resident grid tile (each getting its own parent node, all siblings)
   rather than one single current cell — factor the "given a target Node3D parent and a
   cell FormID, stream terrain+REFRs into it across frames" logic out of `CellLoader`
   so both call sites (door-triggered single-cell swap, continuous grid streaming) share
   it instead of diverging. Matches 2.2 step 1's own stated principle.
2. **World position → grid coordinate.** A small, direct inverse of `cell_loader.gd`'s
   existing terrain-placement math (worth a real headless check against a known cell's
   own world-space bounds, not just algebra by inspection, given how easy the Z-negation
   convention is to get backwards — confirmed necessary once already this phase, for
   REFR rotation composition order).
3. **Streaming radius + resident-set diffing.** Given the active camera's current grid
   coordinate, compute the set of grid coordinates within the streaming radius (a
   simple N×N ring to start — real shape/size is 2.9's tuning problem, not this task's).
   Diff against the currently-loaded set each check: newly-in-range coordinates get
   `find_exterior_cell()` resolved and streamed in (step 1's shared builder); newly-out-
   of-range resident cells get freed immediately (not `queue_free()` — the exact
   same-frame name-collision bug already found and fixed twice this phase in
   `exterior_viewer.gd`/`cell_loader.gd` is just as real with N resident cells as it was
   with one).
4. **Hysteresis, not a single sharp radius.** A camera sitting almost exactly on a
   streaming-radius boundary must not thrash load/unload every check — load at radius R,
   only unload past R+margin, not the same threshold both directions. Needs a real
   back-and-forth walk test to confirm, not just reasoning about it — the same "don't
   trust it until it's been driven across the seam" discipline every boundary-adjacent
   fix this phase has needed.
5. **Persistent-cell-once via `PersistentRoot`**, per the section above — verify no
   duplicate persistent-ref nodes exist with two-plus resident tiles loaded
   simultaneously, not just checked with one.
6. **`activate(wrld_form_id)` / `deactivate()` + `streaming_settled`.** The only API
   surface `game.gd`'s door-transition code needs — see "Purely position-reactive once
   active" above. `deactivate()` tears down every resident tile plus `PersistentRoot` in
   one go (falls out naturally from `WorldStreamer` owning its own resident-set
   bookkeeping, unlike `CellLoader`'s single `_current`). `activate()` does not take a
   position or cell — the very next diff check picks up wherever the camera already is.

## Deliverables

- `CellStreamBuilder`: the shared per-cell terrain+REFR streaming logic, used by both
  `CellLoader`'s door-triggered single-cell path and `WorldStreamer`'s continuous
  multi-tile streaming (not duplicated).
- `WorldStreamer`: keeps every grid tile within a radius of the active camera loaded,
  continuously, with no boundary-cross-triggered gap; a dedicated `PersistentRoot` node
  per active worldspace; `activate(wrld_form_id)`/`deactivate()` as its only
  transition-facing API; a `streaming_settled` signal for a caller to know when it's
  safe to release the player.
- Correct interop with door transitions: entering an interior calls `deactivate()`
  (tears down every resident tile plus `PersistentRoot` in one go); leaving one calls
  `activate()` at the destination worldspace with no explicit cell/position argument.

## Acceptance criteria

- [x] Walking in a straight line across several real grid tiles in `WastelandNV` never
      shows missing terrain/objects at any point — verified by a real, extended visual
      playtest (~1hr): walked across the open Mojave, through Freeside, onto the Strip,
      and reached Primm, crossing multiple worldspace boundaries (Freeside/the Strip are
      real separate worldspaces in NV, not just distant `WastelandNV` tiles — confirms
      `activate()`/`deactivate()` correctly re-target across worldspace changes, not
      just within one) with nothing blocking movement. Various rendering issues noted
      (expected, separately tracked — not a streaming-mechanism problem).
- [x] Free-fly/editor camera movement (not the player body) drives streaming
      correctly — verified directly: `test_world_streamer.gd` drives a plain `Camera3D`
      with no player/CharacterBody3D involved at all, not just the FPC addon's own
      camera.
- [x] A door-triggered teleport into a worldspace with nothing currently resident
      streams in correctly with no special-casing beyond `activate()` — verified via a
      real `game.tscn` instantiation, `RamshackleScrapDoor01`'s own `activate()` through
      `game._do_exterior_transition()`: `CellLoader` torn down, `WorldStreamer` active,
      9 tiles + `PersistentRoot` streamed in from a cold start.
- [x] No duplicate persistent-cell-ref nodes exist with 2+ grid tiles resident at once
      — `test_world_streamer.gd` asserts exactly one `PersistentRoot` exists with 9
      resident tiles loaded.
- [x] `deactivate()` fully tears down every resident tile plus `PersistentRoot`, not
      just whichever tile the player happened to be standing in — verified (resident
      set, pending set, `PersistentRoot`, and child count all confirmed empty/zero/null
      after `deactivate()`).
- [x] `streaming_settled` fires once the post-`activate()` catch-up load actually
      finishes — verified by a real `await` in `test_world_streamer.gd` (caught one real
      GDScript closure gotcha along the way: a lambda mutating a captured local `bool`
      doesn't propagate back to the caller — needed a mutable `Array` container instead).
- [ ] Sitting still near a streaming-radius boundary doesn't thrash load/unload —
      **not yet verified**. What *was* tested is a single large jump (far enough to
      leave the entire old resident set behind), not a real back-and-forth walk
      hovering right at the `RADIUS_LOAD`/`RADIUS_UNLOAD` seam.
- [ ] Cancel/restart safety (a generation counter, per 2.2) re-verified against
      multiple concurrent in-flight tile loads — **not yet explicitly tested**. The
      generation-bump mechanism mirrors 2.2/2.7's already-proven pattern, but no test
      here specifically cancels while several tiles are mid-stream (not yet resident)
      and checks nothing partial leaks through.
