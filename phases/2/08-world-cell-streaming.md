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
stacked on top of each other, not just wasted work. The streamer must load a
worldspace's persistent cell exactly once per active streaming session (tracked
separately from the set of grid tiles), added when streaming starts in that worldspace
and torn down only when leaving it (e.g. through a door into an interior, or into a
different worldspace) — never re-fetched per-tile.

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
5. **Persistent-cell-once**, per the section above: resolve the active grid tile's
   owning worldspace once when streaming (re)starts in it, stream its persistent cell in
   as its own resident entry (not tied to any one grid tile's load/unload lifecycle),
   and tear it down only on a worldspace change — verify no duplicate persistent-ref
   nodes exist with two-plus resident tiles loaded simultaneously, not just checked with
   one.
6. **Integration with 2.7's door transitions.** A door into an interior must tear down
   the *entire* streamed set (every resident exterior tile plus the persistent-cell
   entry), not just whichever single tile the player happened to be standing in — falls
   naturally out of the streamer owning its own resident-set bookkeeping rather than
   `CellLoader`'s existing single `_current`. A door out of an interior into an exterior
   starts the streamer fresh at the destination grid coordinate.

## Deliverables

- A shared per-cell terrain+REFR streaming builder, used by both the door-triggered
  single-cell path and continuous grid streaming (not duplicated).
- A world-cell streamer that keeps every grid tile within a radius of the active
  camera loaded, continuously, with no boundary-cross-triggered gap.
- Persistent-cell refs loaded exactly once per active worldspace streaming session,
  verified with multiple resident tiles simultaneously loaded.
- Correct interop with door transitions: entering an interior tears down the full
  streamed set; leaving one starts streaming fresh at the destination.

## Acceptance criteria

- [ ] Walking in a straight line across several real grid tiles in `WastelandNV` never
      shows missing terrain/objects at any point — verified by an actual walk, not
      just "the loader was called."
- [ ] Free-fly/editor camera movement (not the player body) drives streaming
      correctly — verified directly, not assumed from the player-body case working.
- [ ] No duplicate persistent-cell-ref nodes exist with 2+ grid tiles resident at once.
- [ ] A door transition from a streamed exterior into an interior fully tears down
      every resident tile plus the persistent-cell entry, not just the tile the player
      stood in.
- [ ] Sitting still near a streaming-radius boundary doesn't thrash load/unload
      (hysteresis verified with a real back-and-forth position walk, not reasoning
      alone).
- [ ] Cancel/restart safety (a generation counter, per 2.2) re-verified against
      multiple concurrent in-flight tile loads, not just the single-cell case 2.2/2.7
      already covered.
