# 2.3 — REFR Rotation Composition Order Fix

Parent: [Phase 2](README.md)

## Goal

Fix a real, visually-confirmed placement bug: some `REFR`s render rotated onto the
wrong plane entirely (e.g. a wall-mounted painting facing the ceiling instead of the
room) rather than just being slightly off.

## Finding

`GamebryoMeshResolver.refr_basis()` composed per-axis rotations as `bz*by*bx` (angles
negated, per [00-interior-cell-loader.md](../1/00-interior-cell-loader.md)'s OpenMW
cross-check). That cross-check verified the negation but the composition *order* was
carried over from OpenMW's source without independent verification — and OpenMW is a
Morrowind/Oblivion-era engine reimplementation, not Fallout 3/NV's later Gamebryo fork.
That assumption turned out to be wrong for this engine.

**Found via real user inspection**, not automated testing (same lesson as the original
1.0 rotation bug: a single fixed-angle screenshot looks "coherent enough" while still
being wrong — this needed someone to actually look at specific objects). In
`GSProspectorSaloonInterior`, two adjacent wall-mounted paintings — `TornPaintingLg03`
(rotation `(0°, 0°, 90°)`, renders correctly) and `TornPaintingLg01` (rotation
`(90°, ~0°, 90°)`, rendered face-up against the ceiling) — gave a clean, controlled
counterexample: same object category, same scale, nearly identical Y/Z, differing only
in whether X is zero.

**Root-caused, not just patched around**, in three steps:
1. Confirmed both objects' NIF submeshes have an identity local transform (no baked
   per-model rotation offset) — ruled out "the mesh itself is authored oddly" as the
   cause.
2. Empirically determined what Godot's own `Basis.from_euler(rot, EULER_ORDER_XYZ)`
   actually computes as a matrix product (`bx*by*bz`), rather than assuming from the
   enum name.
3. **Directly visually confirmed** using the user's own placed `Camera3D` in the saved
   scene: re-rendered both paintings from that exact viewpoint under the old and new
   composition order. Old order: `TornPaintingLg01` face-up near the ceiling, exactly
   as reported. New order (`bx*by*bz`): both paintings flush on the wall, facing the
   room correctly.

**Regression-checked broadly, not just the two flagged objects** — a first attempt at
this fix was tested only against a handful of objects and looked like it introduced a
new problem elsewhere; that turned out to be a misjudged screenshot glance (see
"What didn't pan out" below), but it's the reason this fix was re-verified against the
*entire* `GSDocMitchellHouse` cell (screenshot, pixel-comparable to the pre-fix
render — no visible change, as expected: most placements have at most one non-zero
rotation axis, which is composition-order-invariant) plus the full existing test suite
(`test_object_registry.gd`, `test_phase1_integration.gd`, `test_terrain.gd`,
`test_terrain_collision.gd`, `test_resource_caching.gd`) — all still pass.

## What didn't pan out

An earlier pass at this same investigation misjudged a bed in `GSDocMitchellHouse` as
"now rendering diagonally" after applying the order swap, based on a quick glance at a
full-room screenshot, and the fix was reverted on that basis. Re-checked numerically
before trying again: both beds in that cell have rotation `(0°, 0°, ~90°/~97°)` —
X and Y are zero, meaning their basis is **mathematically identical** under either
composition order (verified directly, not just argued). The "regression" was a
misread of something else in that screenshot, not a real effect of the order change.
Lesson reinforced: a screenshot glance is not a substitute for either a numeric check
or a direct, isolated before/after comparison from a fixed camera.

## Deliverables

- `refr_basis()` fixed in `gamebryo/mesh_resolver.gd` (the shared implementation) and
  `test_interior_cell.gd` (a standalone legacy copy predating the shared resolver).
- This write-up.

## Acceptance criteria

- [x] The two flagged real objects (`TornPaintingLg01`, `CampLog01`,
      `RestroomMirror03`) render correctly.
- [x] Fix verified via a direct before/after render from a fixed camera, not just
      argued from matrix algebra.
- [x] Full existing test suite still passes.
- [x] `GSDocMitchellHouse` re-screenshotted and confirmed visually unchanged (expected,
      since most of its placements are rotation-order-invariant).

## What's still open

- `Pillow01` was flagged during the same investigation as still visually wrong under
  manual rotation-order testing done *before* this fix was implemented — that
  observation got carried into an earlier draft of this doc unverified, and asserted
  as still true after the real fix, with an unverified "probably a physics prop"
  explanation attached. Both were wrong: after the actual `bx*by*bz` fix landed,
  `Pillow01` renders correctly. Corrected here rather than left standing — the lesson
  is not to carry forward a pre-fix observation as a post-fix conclusion without
  re-checking it.
- This fix hasn't been exhaustively verified against every object in the base game —
  it's confirmed correct for the counterexamples found so far and mathematically
  provably unchanged for every single-axis rotation (the common case). If further
  rotation anomalies turn up, don't assume this is the only remaining rotation bug.
