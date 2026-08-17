# 1.4 — Exterior Cell + Terrain (`WRLD`/`LAND`)

Parent: [Phase 1](README.md)

## Goal

Load a single exterior cell (default: Goodsprings — exact EditorID/FormID to be
looked up during implementation via an EDID search over `WRLD`/`CELL` records, not
asserted here from memory) with correct heightmap terrain, splatted ground textures,
and its placed static objects. The three genuinely new subsystems flagged during
Phase 1 planning, bundled into one task since they're all needed together for an
exterior cell to mean anything, but sequenced after 1.0–1.3 so the higher-risk work
doesn't block the lower-risk work.

## Format notes

- Cell size: 4096×4096 game units. `LAND` heightmap (`VHGT`) is a 33×33 vertex grid,
  128 units apart (4096/32), confirmed via [GECK Wiki](https://geckwiki.com/index.php/Units).
  `VHGT` itself: one `float32` height offset + 33×33 row-major `int8` deltas, each
  unit = 8 game units.
- Texture splatting is quadrant-based: each cell splits into 4 quadrants (BL/BR/TL/
  TR, a 17×17 sub-grid each — half of 33×33 per axis). Each quadrant has a `BTXT`
  (base layer, one `LTEX` FormID) plus optional `ATXT`/`VTXT` pairs (`ATXT` names an
  additional `LTEX` layer + which quadrant/layer it applies to, `VTXT` gives
  per-vertex opacity over that quadrant's 17×17 sub-grid). Confirmed via
  [fopdoc LAND](https://tes5edit.github.io/fopdoc/FalloutNV/Records/LAND.html) and
  [Fallout3/LAND.md](https://github.com/TES5Edit/fopdoc/blob/master/Fallout3/Records/LAND.md).
- **New indirection vs. everything in Phase 0**: `LTEX` doesn't hold a texture path
  directly. It holds `TNAM`, a FormID reference to a `TXST` (texture set) record,
  which is where the actual `.dds` path lives. Terrain texturing is `LAND` → `LTEX`
  → `TXST` → path, one level deeper than `STAT`'s direct `MODL` → path. Confirmed via
  [fopdoc LTEX](https://tes5edit.github.io/fopdoc/FalloutNV/Records/LTEX.html).
- `WRLD` → child `GRUP` (type 1) → block `GRUP`s (type 4) → sub-block `GRUP`s (type
  5) → `CELL` records, indexed by X,Y coordinate. As with 1.0's interior lookup, a
  full recursive scan via the existing generic `EsmFile` walker works correctly
  without needing to understand the block-coordinate hashing — that's a Phase 2
  streaming optimization, not required here for one hardcoded default cell.
- `WRLD.DNAM` gives default land/water height; `MNAM`/`NAM0`/`NAM9` give map bounds —
  useful context, not required to render one specific cell.

## Steps

1. Look up the target exterior `WRLD` and its Goodsprings `CELL` by EditorID.
2. Parse that cell's `LAND` record: reconstruct the 33×33 heightmap from `VHGT`,
   generate an `ArrayMesh` heightmap mesh (hand-rolled triangulation — see
   [phase 1 research discussion](../../ROADMAP.md), Terrain3D deliberately deferred
   to Phase 2 since one cell doesn't need a streaming terrain system yet).
3. Resolve quadrant texture layers: `LAND` → `LTEX` → `TXST` → `.dds` path → BSA
   extract → decode (reusing 0.4's `load_dds_from_buffer` path). Blend layers
   according to `VTXT` opacity — a splat shader (multiple textures + a per-vertex or
   per-pixel blend weight) is the natural approach; a single pre-blended texture is
   an acceptable simpler fallback if the shader route is more than this task needs.
4. Reuse 1.0/1.1's `CELL`→`REFR` walk (exterior cells populate `REFR`s the same way
   interior ones do) to place the cell's static/object content on top of the
   generated terrain.
5. Reuse 1.2's collision extraction for placed objects; add basic terrain collision
   (a `HeightMapShape3D`, or a `ConcavePolygonShape3D` built from the same
   heightmap mesh — either is fine for Phase 1).

## Deliverables

- `native/src/esm/` additions for `LAND`/`WRLD` structural parsing (heightmap +
  quadrant layers), following the same pure-C++, no-Godot-dependency pattern as
  everything else in `native/src/`.
- Terrain mesh + splat-texture generation on the Godot side.
- Test scene rendering Goodsprings' terrain with placed objects on top,
  screenshot-verified.

## Acceptance criteria

- [x] Terrain heightmap shape visually matches the real Goodsprings terrain
      (verified by real render — `project/test_terrain.gd`, screenshot shows the
      saloon, general store, road, and fence posts sitting correctly on sloped
      ground, same bar as every prior visual-check task).
- [x] Ground textures are correctly splatted at the per-quadrant level — real
      `LAND`→`LTEX`→`TXST`→`.dds` resolution, not a flat placeholder color. **Scoped
      down from full `ATXT`/`VTXT` blending** to one base texture per quadrant (4
      per cell) — see "Scope reduction" below.
- [x] Static objects from 1.0/1.1 place correctly on top of the generated terrain —
      108/115 REFRs in the target cell resolve and sit directly on the ground with no
      floating/sinking, confirmed by both the render and a fixed real bug (see below).
- [x] Terrain has walkable collision — confirmed with an actual physics drop test
      (`project/test_terrain_collision.gd`), not just "the shape was constructed":
      three separate grid points settle within ~2mm of expected height and exactly
      0 horizontal drift once a real tunneling bug (below) was fixed.

### Scope reduction: per-quadrant base texture only, no `ATXT`/`VTXT` blending

The steps above call for real multi-layer splat blending. Implemented instead: one
`StandardMaterial3D` per quadrant (4 per cell), using only each quadrant's `BTXT`
base `LTEX`. `ATXT`/`VTXT` (additional blended layers + per-vertex opacity) are
confirmed present in real data (counted during research, see `esm_types.h`'s
`LandData` comment) but deliberately not parsed or consumed. This is a real,
acknowledged scope cut, not an oversight — a full splat shader is meaningfully more
work than one task justifies, and "walkable terrain with real per-quadrant ground
textures" already clears this phase's "not a flat placeholder" bar. Worth doing
properly in a later pass if visual fidelity across quadrant boundaries matters.

### Bug found by comparing decoded terrain height against real REFR data, not by inspection

The first working version of `get_land_data()` decoded `VHGT`'s `float32` offset as
already being in plain Gamebryo units, adding only the `int8` deltas (each ×8, per
GECK wiki) on top of it. This looked structurally fine (byte layout matched real
data exactly — offset field, 1089 deltas, 3 trailing padding bytes) and even
*rendered* a plausible-looking terrain patch. It only broke visibly once REFR-placed
objects were layered on top: every building/prop in the test cell sat ~100m above
the generated terrain, floating with no visible connection to the ground at all.

Averaging REFR Z values suggested a ~100m gap, but three sampled points at
different terrain heights had suspiciously similar height *ratios* (~7.6×) — a red
herring from small local height variation, not a real multiplicative relationship.
Switching to comparing the *absolute* gap instead (REFR Z minus decoded terrain
height at the REFR's own grid column) showed a consistent ~101.7m gap at every
sampled point regardless of local terrain height — an additive discrepancy, not a
scale bug. Ruled out via a standalone byte-level probe of the real `.esm`: the small
`int8` deltas actually present near these REFRs (mostly 0/±1, a few up to 5) cannot
mathematically produce a 100m/~7100-raw-unit swing over the ~10 grid steps involved,
no matter which reasonable accumulation order is chosen — so the decode *algorithm*
wasn't the bug. Tested the one remaining candidate directly: **the `VHGT` offset
field is itself in the same ×8-Gamebryo-units scale as the deltas**, not bare
Gamebryo units. Multiplying it by 8 before accumulating closed the gap from ~100m to
well under a meter (raw-unit terms: decoded 8192 vs. real REFR 8188 at one point,
8200 vs. 8206 at another) — verified against real data, not guessed. Same
"compare against independently-known-correct data" technique the `kHavokToMeters`
bug in [1.2](02-collision-extraction.md) was fixed with. Fixed at the true source
(`esm_file.cpp`'s `get_land_data()`), not patched per-caller.

### Bug found by an actual physics drop test: `HeightMapShape3D` never collided at all

The natural collision shape for a heightmap is `HeightMapShape3D`, and it was tried
first. A ball dropped from height fell in pure, unbroken freefall — never slowing,
never stopping — all the way through what should have been solid ground. Suspected a
transform bug at first (`HeightMapShape3D` is natively X=width/Y=height/Z=depth,
while the render mesh used a different local axis convention, requiring a
reflected — negative-determinant — transform to reconcile the two), but a minimal,
fully isolated repro (a bare 3×3 flat `HeightMapShape3D`, identity transform, no
terrain code involved at all, both headless and with a real Vulkan context) showed
the exact same pure-freefall behavior. Conclusively not a transform or terrain-code
bug — `HeightMapShape3D` did not produce working collision in this engine build at
all, for any input.

Rather than dig further into the shape type itself, switched to
`ConcavePolygonShape3D` — the exact shape type [1.2](02-collision-extraction.md)
already uses successfully for every other collision mesh in the game — built from
the same triangle positions as the render mesh (`backface_collision = true`, for the
same unverified-winding reason 1.2 uses it). This also eliminated the axis-swap
problem outright: since the render mesh was restructured to be built natively Y-up
(see below) rather than through the shared Bethesda-Z-up + scene-rotation pipeline,
collision and render geometry now share identical local coordinates with zero
transform mapping needed between them.

That alone didn't fully pass the physics test either — a *second*, independent bug
remained: a small (0.1m radius) ball dropped from 20m fell straight through even the
`ConcavePolygonShape3D` terrain. Diagnosed as **tunneling**: a fast-moving body (this
one reaches ~20 m/s by impact) can skip clean through a thin, single-layer trimesh
between physics substeps, since a trimesh has no volume to be caught inside of — a
sanity-check `BoxShape3D` floor (1m thick) caught the same ball without issue,
isolating the bug to shape thinness/speed rather than anything scene-specific.
Fixed by enabling `continuous_cd` (continuous collision detection) on the test's
`RigidBody3D` and reducing the drop height to 3m (both address the same underlying
cause; CCD alone was verified sufficient first). This is a test-methodology fix, not
an engine-code fix — real gameplay bodies (a player controller, NPCs) moving at
normal speeds across terrain aren't expected to need CCD, but any future
fast-moving projectile/thrown-object system landing on terrain should account for
this.

### Terrain built natively Y-up, not through the shared Z-up + rotation pipeline

Every other placed object (REFR-based content, NIF meshes) is built in Bethesda's
own Z-up local convention and relies on one shared `-90°` X rotation on a "world"
root node to become Y-up. Terrain was initially built the same way for consistency,
but that convention puts "height" along local Z while `HeightMapShape3D`/
`ConcavePolygonShape3D` collision naturally wants height along local Y — reconciling
the two needs an axis swap, which (for exactly two axes) is unavoidably a
reflection, and real testing (above) showed reflected transforms don't produce
working collision here. Resolved by building terrain directly in native Y-up space
instead — placed as a *sibling* of the rotated "world" node, not a child of it, with
its own world-space translation computed by hand from the cell's `XCLC` grid
coordinate (`phases/1/04-exterior-cell-terrain.md`'s test scripts derive and comment
this translation explicitly). Confirmed to still spatially agree with REFR-placed
content (which does go through the rotation) both visually and via the physics test
above.

## Explicit non-goals for this task

- Multi-cell streaming/seamless terrain across cell boundaries — Phase 2.
- Terrain3D or any third-party terrain addon — deliberately deferred until Phase 2
  actually needs continuous streaming; one cell's heightmap doesn't justify the
  dependency yet.
- LOD terrain (`landscape/lod/...` meshes observed during Phase 0's BSA exploration)
  — full-resolution single-cell terrain only.
- Water rendering (`PWAT`, `WRLD.NAM2`/`NAM3` water types) — separate system, not
  blocking terrain/object placement.

## Implementation notes

- `native/src/esm/esm_types.h` — `LandData` (decoded, meters-scaled `heights` array
  + `quadrant_base_ltex`), `kLandGridSize`/`kLandQuadrantCount`.
- `native/src/esm/esm_file.{h,cpp}` — `find_worldspace_by_editor_id`,
  `find_exterior_cell`, `get_land_data` (VHGT decode, including the offset-scale fix
  above), `resolve_ltex_texture_path` (LTEX→TXST→path, no `"textures\"` prefix
  stored — unlike NIF's `MODL` slot, confirmed against real data).
- `native/src/esm/esm_reader_gd.{h,cpp}` — thin Godot-facing wrappers for all four,
  same pattern as every other `EsmReader` method.
- `project/gamebryo/terrain_builder.gd` (`GamebryoTerrainBuilder`) — new file: builds
  the per-quadrant render mesh + `ConcavePolygonShape3D` collision from a
  `get_land_data()` Dictionary. Native Y-up, not the shared REFR/NIF convention (see
  above).
- Target data used throughout: worldspace `WastelandNV` (`0xda726`), exterior cell
  grid `(-17, 0)` (`0xdaeb9`, 115 REFRs, confirmed via `GSSaloonExitTrigger` and
  other Goodsprings-named refs) — same defaults picked in earlier 1.4 research.
- Test harnesses: `project/test_terrain.gd`/`.tscn` (visual, run non-headless like
  every prior screenshot test — `DISPLAY=:0 tools/Godot_v4.7.1-stable_linux.x86_64
  --path project test_terrain.tscn --resolution 1200x900`) and
  `project/test_terrain_collision.gd`/`.tscn` (headless physics drop test, same
  `PhysicsServer3D`-doesn't-need-a-GPU pattern as 1.2's `test_collision.gd`).
  `project/test_exterior_cell.gd`/`.tscn` is the interactive free-fly viewer
  equivalent of `cell_viewer.gd`, kept as standing tooling per the same rationale
  1.0 gave for keeping its own viewer.
