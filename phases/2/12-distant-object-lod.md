# 2.12 — Distant Object LOD

Parent: [Phase 2](README.md)

## Goal

ROADMAP's own remaining Phase 2 bullet: "Distant terrain / object LOD (FNV ships
pre-baked LOD meshes and distant land data — reuse them rather than generating LOD at
runtime, at least initially)." Scoped down to **object LOD only** by this task — the
"terrain" half is explicitly deferred: this engine ships no separate pre-baked terrain-
LOD mesh format at all (confirmed, see `enginedocs/lod.md`), and terrain rendering is
expected to move to Terrain3D at some point, which has its own LOD system — building a
terrain-LOD mechanism now would likely be thrown away.

The underlying engine/data facts this task builds on are documented separately in
[`enginedocs/lod.md`](../../enginedocs/lod.md) (pure findings, no solution notes) —
this doc is the *how*, that one is the *what's actually there*. Read it first; this doc
assumes it.

## What's already true, confirmed against real data (not assumed)

Summarized from `enginedocs/lod.md`, with the specific implications for this task:

- **Object LOD is a paired-mesh convention**: `<basename>_lod.nif` sits next to
  `<basename>.nif` in the same BSA folder — 1,647 real pairs across the shipped BSAs
  (architecture, landscape rock/cliff formations, dungeons, SCOL, clutter, vehicles,
  trees). Deriving the LOD path is simple suffix insertion, not a lookup table.
- **The real eligibility gate is the `REFR`'s own "Visible When Distant" flag** (bit
  `0x00008000` in the record's header flags), not "does a `_lod.nif` happen to exist for
  the model" — confirmed directly: some placements of models that DO have a `_lod.nif`
  companion (`NVNellisQuonsetHut01`/`02`, `CraneStatic01`) are NOT VWD-flagged, while
  others (`Barracks01`/`02`) are. Building LOD variants purely off file-existence would
  render more distant LOD than the real game does.
- **This project's own `ReferencePlacement`/`get_cell_references()` doesn't expose
  record flags to GDScript at all yet** — a real, scoped gap, not a design choice. Step
  1 below closes it.
- **Real per-category distance tuning exists** (`fLODFadeOutMultObjects`/`Actors`/
  `Items`, `fLODBoundRadiusMult`, `fLodDistance`, quality-preset-scaled) and is likely
  size-proportional (bigger objects fade to LOD farther out), not a flat number — but
  this exact formula is *inferred* from the ini's own shape, not confirmed against
  engine source. Per explicit user direction, this task starts with **one configurable
  global crossover distance**, not the full per-category/size-proportional system —
  the real tuning data stays recorded in `enginedocs/lod.md` for whenever that's worth
  building.

## Real content density (measured, not guessed)

Surveyed a real 101×101-cell grid centered on Goodsprings (10,201 real cells, 141,138
total placements) with a standalone tool bypassing the GDScript layer entirely, checking
each `REFR`'s actual record flags and `_lod.nif` availability directly:

- **15,313 placements (10.85% of everything) are VWD-flagged with a resolvable
  `_lod.nif`** — not sparse, corrects an earlier assumption in this task's own
  discussion. Every VWD-flagged placement checked had a resolvable `_lod.nif` (though
  the reverse isn't true — see `enginedocs/lod.md`'s QuonsetHut/CraneStatic finding).
- **But only 356 unique base models** among those 15,313 placements. The top of the
  list is dominated by repeated natural scenery, not buildings: `NVN_CliffCanyonL01`
  (1,463 placements), four Joshua tree variants (~3,766 placements combined),
  `NVN_RockCanyon07` (786), several more cliff/rock/road models in the hundreds each.
- **This matters directly for cost**: resolve cost is bounded by the 356 unique models
  (cached, same as any other model — see Design below), not the 15,313 placement count.
  The placement count only turns into cheap `MultiMesh` transform entries once the
  underlying mesh is built.
- Ring-by-ring (Chebyshev distance from Goodsprings), summed for a radius-4-to-10 band
  (the specific split under discussion — full detail out to ring 4, LOD out to ring 10):
  **~11,084 total placements, of which ~878 are VWD+LOD-eligible** in that added band —
  a small, bounded addition, not a runaway volume.
- Still unverified: real end-to-end wall-clock cost of actually streaming a widened
  radius through the real pipeline (this survey was a standalone tool, not the real
  `WorldStreamer` path), and combined `MultiMesh` instance-count behavior at
  normal-streaming-plus-LOD scale together. Not assumed fine — acceptance criteria below
  call for measuring it for real.

## Confirmed Godot API surface (checked against real docs, not assumed)

- `GeometryInstance3D.visibility_range_begin`/`_end` (+ `_begin_margin`/`_end_margin`,
  + `visibility_range_fade_mode`) — per-instance distance-based visibility, built into
  every Node3D that renders geometry. `begin` = distance below which hidden; `end` =
  distance beyond which hidden (0 = disabled). Godot's own docs call
  `VISIBILITY_RANGE_FADE_DISABLED` (hard cutover + hysteresis via the margins) "the
  fastest approach to manual LOD" — `SELF` (this instance crossfades itself, Forward+
  only) and `DEPENDENCIES` (fades a group registered via `Node3D.visibility_parent`)
  exist for smoother but costlier transitions.
- `RenderingServer.instance_geometry_set_visibility_range(instance: RID, min, max,
  min_margin, max_margin, fade_mode)` — confirmed directly equivalent to the
  `GeometryInstance3D` properties above, and works on a bare RID with no Node at all.
  This is what makes the mechanism usable from `DirectGeometryBatch` (2.9) directly,
  not just the Node-based path.

## Design

Two pre-authored meshes, complementary visibility ranges, same transform:

- Full-detail mesh: `visibility_range_end = D` (visible only within `D`).
- `_lod.nif` mesh: `visibility_range_begin = D` (visible only beyond `D`).
- `D` = one project-wide configurable constant for this task (see Goal's own scoping
  note) — a small hysteresis margin on both to avoid flicker right at the boundary,
  `VISIBILITY_RANGE_FADE_DISABLED` to start (cheapest, matches Godot's own manual-LOD
  guidance; revisit `SELF`-mode crossfading later if the hard cut looks bad in practice).

**Node-based path** (`CellLoader`'s editor-preview `build()`, and any future registered-
type factory that wants it): a second `MeshInstance3D` per submesh, built from the
`_lod.nif`'s own resolved geometry, sharing the placement's transform; visibility range
set on both the full and LOD `MeshInstance3D`.

**RID-based path** (`DirectGeometryBatch`, what `WorldStreamer` actually uses at
runtime): a second `MultiMesh` tier, grouped by the LOD mesh resource — the same
"one `MultiMesh` per distinct mesh, not per placement" pattern `DirectGeometryBatch`
already uses for full-detail meshes, just a second parallel set of groups. Visibility
range is set once per `MultiMesh` instance (via `instance_geometry_set_visibility_range()`
on its own `RID`), not per placement inside it — every placement sharing a given mesh
shares the same crossover distance, consistent with the "one global constant" scope.

**Eligibility**: only placements that are (a) VWD-flagged (per `enginedocs/lod.md`'s own
finding) AND (b) have a resolvable `_lod.nif` companion get the second mesh/MultiMesh
tier at all. Everything else (the overwhelming majority of placements) is completely
unaffected — no visibility range set, same as today.

### One widened streaming radius, not a second streaming system

Originally considered a separate, coarser "VWD-only wide-radius pass" alongside the
existing full-detail streaming. Rejected in favor of something simpler once the
`visibility_range_begin`/`end` mechanism is understood properly: Godot checks that
property every frame on its own, on its own timeline — `WorldStreamer` never needs to
dynamically swap anything as the player moves, it only needs the relevant geometry to
already exist, with the right static visibility-range values set once at construction.

So the actual shape is: **`WorldStreamer`'s existing resident-tile radius (`RADIUS_LOAD`)
gets pushed out to cover the LOD distance**, and every tile — near or far — goes through
exactly the same `resolve_placement()`/`construct_from_resolved()` path already built.
The only new behavior is a cheap early-exit inside `resolve_placement()`: check a
placement's VWD flag *before* touching NIF/BSA at all, and for a tile past the
full-detail sub-radius, a non-VWD placement resolves straight to `"kind": "skip"` without
ever loading its model. This is exactly why the 356-unique-model/15,313-placement survey
above matters — most of what a far tile scans gets discarded at that cheap check, so
widening the radius doesn't multiply real resolve work anywhere near as much as widening
it for full-detail streaming would.

Concretely: two radius constants instead of one (`RADIUS_LOAD_FULL` ~4,
`RADIUS_LOAD_DISTANT` ~10, both still tunable pre-runtime, no hardcoded assumption about
final values), no second cache layer, no second worker-task type, no second
`DirectGeometryBatch`-equivalent class — the existing one just grows a second `MeshGroup`
tier (per the RID-based path description above).

## Step-by-step implementation TODO

1. **Expose `REFR` record flags to GDScript.** Add a `flags` (or a pre-decoded
   `visible_when_distant: bool`) field to `esm::ReferencePlacement`
   (`native/src/esm/esm_types.h`) and thread it through `EsmFile::get_cell_references()`
   / `EsmReader::get_cell_references()`'s GDScript-facing Dictionary. Verify directly
   against the same real placements already checked in `enginedocs/lod.md` (Barracks
   VWD=true, QuonsetHut/CraneStatic VWD=false) — a regression test fixture, not just a
   one-off confirmation.
2. **Derive the LOD companion path** from a placement's own `model` (suffix insertion
   before `.nif`, case-insensitive per this codebase's existing BSA-lookup convention)
   and confirm resolvability via the existing `resolve_bytes()`/BSA-priority search —
   most placements won't have one, that's the common, valid case, not an error.
3. **Widen `WorldStreamer`'s own resident radius** into two tunable constants
   (`RADIUS_LOAD_FULL`, `RADIUS_LOAD_DISTANT` > `RADIUS_LOAD_FULL`) and thread which
   band a given tile falls in down to its own `resolve_tile()` call, so
   `resolve_placement()` knows whether to attempt full-detail resolve at all for a given
   placement or go straight to the VWD-gated early-exit described in Design above.
4. **Extend the raw-resolve step** (`GamebryoObjectRegistry.resolve_placement()`/
   `_resolve_visual()` and friends, `GamebryoMeshResolver.resolve_raw_geometry()`) so a
   VWD-flagged, LOD-resolvable placement's result carries a second, optional raw
   geometry block for the LOD mesh alongside the existing full-detail one (full-detail
   itself only attempted inside the `RADIUS_LOAD_FULL` band, per step 3). Stays within
   phases/2/10's own worker-safe/main-thread-only split — LOD raw-resolve is exactly as
   worker-safe as full-detail raw-resolve, no new thread-safety surface.
5. **Extend `build_geometry_entries()`** (main-thread-only, per 2.10) to build the LOD
   mesh's actual `ArrayMesh`/material the same way it already does for full-detail,
   when present, using the same cache-by-key discipline already established.
6. **Node-based construct path**: `populate_mesh_children()` (or a sibling) builds the
   second `MeshInstance3D` and sets both instances' visibility range properties when a
   built LOD entry is present.
7. **RID-based construct path**: extend `DirectGeometryBatch` with a second internal
   `MeshGroup` tier for LOD meshes (mirroring the existing full-detail grouping in
   `add_object()`/`build()`), and call `instance_geometry_set_visibility_range()` on
   each tier's own instance RID once built. `_construct_direct()`
   (`GamebryoObjectRegistry`) passes the LOD geometry through when present.
8. **DONE.** The configurable crossover distance itself: `GamebryoMeshResolver` gained
   real `lod_crossover_distance_m`/`_margin_m` instance fields (default 100.0/5.0,
   matching steps 6/7's placeholder constants) plus a `set_lod_crossover()` setter
   (mirrored on `DirectGeometryBatch` for the RID side); `WorldStreamer` and `CellLoader`
   each gained matching `@export` values and call the setter once in `_ready()`, so
   there's exactly one real, inspector-tunable number reaching both the Node-based and
   RID-based paths, not two matching constants in two languages. Still a flat global
   placeholder, not the real per-category/size-proportional system `enginedocs/lod.md`
   describes.
9. **DONE.** Measured the widened radius for real, same headless benchmark methodology
   as 2.10/2.11 (`_diag_construct_cost.gd`), at `RADIUS_LOAD_FULL=1`/`RADIUS_LOAD_DISTANT=10`
   (this task's own current tuning) — compared directly against the same radius with
   `RADIUS_LOAD_FULL` temporarily forced to 10 (i.e. every tile fully resolved, the
   pre-2.12-equivalent cost of streaming this same radius with no VWD gating at all),
   then reverted:

   | | VWD-gated (real config) | forced full-detail (pre-2.12-equivalent) |
   |---|---|---|
   | total settle wall time | 2534ms | 3020ms |
   | main-thread construct SUM | 174ms | 461ms |
   | resolve_wall SUM (pooled, parallel) | 572,182ms | 652,511ms |

   Confirms the standalone survey's "cheap because of the VWD early-exit" claim through
   the real pipeline: 16% faster to settle overall, and the main-thread construct step
   (the part that actually risks a frame stutter, since it's not pooled across workers)
   is 62% cheaper. `refcount_per_tile` was unchanged (avg 37.38 either way) — that
   instrumentation counts resolved results per tile, not gated by this step, so an
   unchanged value there is expected, not a discrepancy.
10. **Verify in real play**: walk toward a known VWD-flagged large object (e.g. a real
    Barracks placement) from beyond the configured crossover distance, confirm the LOD
    mesh shows first and swaps to full detail at the right distance, no popping/z-fighting
    at the boundary, and that a non-VWD-flagged object with a `_lod.nif` companion
    (e.g. a QuonsetHut) correctly stays full-detail-or-nothing (matching the real game's
    own eligibility gate) rather than ever showing its LOD variant.

## Deliverables

- `ReferencePlacement`/`get_cell_references()` exposing VWD eligibility to GDScript. DONE.
- `WorldStreamer` streaming one widened radius (`RADIUS_LOAD_FULL`/`RADIUS_LOAD_DISTANT`),
  not a second parallel streaming system, with a cheap VWD-gated early-exit for the
  outer band. DONE.
- LOD-companion resolution folded into the existing raw-resolve/final-build split
  (2.10), no new thread-safety surface, no new cache layer. DONE.
- Both the Node-based and RID-based (`DirectGeometryBatch`) construct paths supporting
  a second, distance-gated mesh tier. DONE.
- One configurable global crossover distance (plus the two configurable radii above). DONE.

## Acceptance criteria

- [x] VWD flag correctly read for real placements already spot-checked in
      `enginedocs/lod.md` (Barracks true, QuonsetHut/CraneStatic false) — a permanent
      regression test, not just a one-off confirmation. (`test_visible_when_distant.gd`)
- [ ] A VWD-flagged placement with a resolvable `_lod.nif` shows the LOD mesh beyond the
      configured distance and the full mesh within it, in real play, with no visible
      pop/gap at the crossover (hysteresis margin doing its job). Step 10, not done yet.
- [ ] A placement with a `_lod.nif` companion but no VWD flag never shows the LOD
      variant — confirmed directly, not assumed from the eligibility check alone. Step 10
      real-play part not done yet (the resolve/construct-level version of this IS
      confirmed — `test_lod_raw_geometry.gd`/`test_lod_construct_node.gd`/
      `test_lod_direct_batch.gd` all verify QuonsetHut01 never gets an LOD tier).
- [x] The overwhelming majority of placements (no VWD flag, or no `_lod.nif` companion)
      are completely unaffected — no visibility range set, no behavior change, confirmed
      via the existing regression suite passing unmodified.
- [x] Both the Node-based (`CellLoader` editor-preview) and RID-based (`WorldStreamer`/
      `DirectGeometryBatch`) paths verified — not just one. (`test_lod_construct_node.gd`,
      `test_lod_direct_batch.gd`)
- [x] Real measured settle-time/frame-cost impact of widening the radius to
      `RADIUS_LOAD_DISTANT`, using the same headless benchmark methodology already
      established this phase — the standalone survey's "cheap because of the VWD
      early-exit" claim is confirmed through the real pipeline, not just argued from the
      survey numbers alone. See step 9 above (2534ms vs 3020ms settle time, 174ms vs
      461ms main-thread construct SUM).
- [x] Terrain LOD stays explicitly out of scope — no attempt to build a terrain-LOD
      mechanism as part of this task.
