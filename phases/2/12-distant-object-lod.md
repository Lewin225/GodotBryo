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
3. **Extend the raw-resolve step** (`GamebryoObjectRegistry.resolve_placement()`/
   `_resolve_visual()` and friends, `GamebryoMeshResolver.resolve_raw_geometry()`) so a
   VWD-flagged, LOD-resolvable placement's result carries a second, optional raw
   geometry block for the LOD mesh alongside the existing full-detail one. Stays within
   phases/2/10's own worker-safe/main-thread-only split — LOD raw-resolve is exactly as
   worker-safe as full-detail raw-resolve, no new thread-safety surface.
4. **Extend `build_geometry_entries()`** (main-thread-only, per 2.10) to build the LOD
   mesh's actual `ArrayMesh`/material the same way it already does for full-detail,
   when present, using the same cache-by-key discipline already established.
5. **Node-based construct path**: `populate_mesh_children()` (or a sibling) builds the
   second `MeshInstance3D` and sets both instances' visibility range properties when a
   built LOD entry is present.
6. **RID-based construct path**: extend `DirectGeometryBatch` with a second internal
   `MeshGroup` tier for LOD meshes (mirroring the existing full-detail grouping in
   `add_object()`/`build()`), and call `instance_geometry_set_visibility_range()` on
   each tier's own instance RID once built. `_construct_direct()`
   (`GamebryoObjectRegistry`) passes the LOD geometry through when present.
7. **The configurable crossover distance itself**: one exported/constant value,
   plumbed to wherever step 5/6 need it (`WorldStreamer` and/or `CellLoader`) — explicit
   about being a placeholder for the real per-category/size-proportional system
   `enginedocs/lod.md` describes, not a final tuned value.
8. **Verify in real play**: walk toward a known VWD-flagged large object (e.g. a real
   Barracks placement) from beyond the configured crossover distance, confirm the LOD
   mesh shows first and swaps to full detail at the right distance, no popping/z-fighting
   at the boundary, and that a non-VWD-flagged object with a `_lod.nif` companion
   (e.g. a QuonsetHut) correctly stays full-detail-or-nothing (matching the real game's
   own eligibility gate) rather than ever showing its LOD variant.

## Deliverables

- `ReferencePlacement`/`get_cell_references()` exposing VWD eligibility to GDScript.
- LOD-companion resolution folded into the existing raw-resolve/final-build split
  (2.10), no new thread-safety surface.
- Both the Node-based and RID-based (`DirectGeometryBatch`) construct paths supporting
  a second, distance-gated mesh tier.
- One configurable global crossover distance.

## Acceptance criteria

- [ ] VWD flag correctly read for real placements already spot-checked in
      `enginedocs/lod.md` (Barracks true, QuonsetHut/CraneStatic false) — a permanent
      regression test, not just a one-off confirmation.
- [ ] A VWD-flagged placement with a resolvable `_lod.nif` shows the LOD mesh beyond the
      configured distance and the full mesh within it, in real play, with no visible
      pop/gap at the crossover (hysteresis margin doing its job).
- [ ] A placement with a `_lod.nif` companion but no VWD flag never shows the LOD
      variant — confirmed directly, not assumed from the eligibility check alone.
- [ ] The overwhelming majority of placements (no VWD flag, or no `_lod.nif` companion)
      are completely unaffected — no visibility range set, no behavior change, confirmed
      via the existing regression suite passing unmodified.
- [ ] Both the Node-based (`CellLoader` editor-preview) and RID-based (`WorldStreamer`/
      `DirectGeometryBatch`) paths verified — not just one.
- [ ] Terrain LOD stays explicitly out of scope — no attempt to build a terrain-LOD
      mechanism as part of this task.
