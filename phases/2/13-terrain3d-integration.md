# 2.13 — Terrain3D Integration (design doc; implementation in progress)

Parent: [Phase 2](README.md)

## Status

Started as design/research only; implementation sequence now underway. Steps 1–2 of
the "Proposed implementation sequence" below are done and real-data-verified
(addon vendored and loading, real-cell heightmap import round-trips bit-exact). Steps
3 onward (the real-data census work informing texture/grass design) were also
completed out of order, before formal implementation began — see "Real-data
findings." Remaining steps (control-map painting, collision, `WorldStreamer`
integration, grass) are not yet started. Several sections below still list open
questions that needed (and got) real-data answers before their part of
implementation could start — see "Open questions requiring real-data research."

**Update:** all three of those open questions (ATXT/VTXT layer counts, the LTEX/TXST
texture budget, and whether FNV encodes grass data anywhere) have since been resolved
against real data via a standalone research tool,
`native/tools/terrain_census.cpp` — see "Real-data findings" below and the updated
compatibility table/open-questions entries. The texture-budget question took two
passes to get right: an initial per-region check at `region_size = 256` looked
sufficient but wasn't (a single resident region fit under 32, but realistic
concurrent-neighbor residency didn't) — re-measuring across three region sizes found
`region_size = 64` closes it completely, backed by an LRU eviction pool + reserved
"missing texture" fallback slot as a safety net for cases outside the measured
approximation. The tool is a one-off, read-only research artifact (kept in the repo
per this project's established `native/tools/`-as-standalone-C++-CLI convention, same
as `dump_object`), not part of the GDExtension build.

## Goal

Replace the current per-cell terrain system (`phases/1/04-exterior-cell-terrain.md`'s
`GamebryoTerrainBuilder` — one hand-rolled `ArrayMesh` + `ConcavePolygonShape3D` per
cell, base-texture-only, no LOD, rebuilt/discarded on every stream in/out) with
[Terrain3D](https://terrain3d.readthedocs.io/en/stable/index.html), a third-party Godot
4 terrain addon: clipmap LOD mesh, region-based streaming data model, up to 32-texture
splat painting, and a foliage/instancer system. This is explicitly deferred work per
`ROADMAP.md`'s Phase 2 bullet ("Distant terrain... FNV ships pre-baked LOD meshes and
distant land data — reuse them rather than generating LOD at runtime, at least
initially") and `phases/1/04-exterior-cell-terrain.md`'s own non-goals ("Terrain3D or
any third-party terrain addon — deliberately deferred until Phase 2 actually needs
continuous streaming").

## Why now

The current terrain system was scoped for "one cell, loaded once, no performance
target" (Phase 1). Phase 2's streaming system (2.8–2.12) now loads/unloads many cells
continuously, and terrain construction sits inside that hot path (`world_streamer.gd`'s
`_construct_results()` calls `CellStreamBuilder.build_terrain()`, historically ~75% of
that call's own cost per the comment in `world_streamer.gd`). The current system also
has no LOD for distant terrain (unlike 2.12's object LOD) and no real multi-layer
texture blending (a Phase 1 scope cut — `ATXT`/`VTXT` are parsed-present-but-unread).
Terrain3D directly addresses both: a clipmap mesh gives free distance-based LOD, and
its control-map format gives real per-pixel texture blending without a custom shader.

## Terrain3D's actual data model (sourced from the library's own docs)

Recorded here because it materially shapes the design below — this is not how our
current per-cell system works, and the differences are the crux of the compatibility
questions.

- **Regions**, not cells, are the resident/streaming unit. A region is a square area
  of `region_size` vertices/pixels per side (`region_size` ∈ {64, 128, 256, 512, 1024,
  2048}, default 256), holding one height-map `Image`, one control-map `Image`, and one
  color-map `Image`. `Terrain3DData.region_locations` is the live `Array[Vector2i]` of
  which regions currently exist.
- **`vertex_spacing`** (default `1.0`) is the world-space distance between adjacent
  height/control pixels — i.e. 1 Godot unit (meter) per pixel by default, but freely
  adjustable; changing it rescales the whole terrain's lateral (X/Z) size without
  touching the underlying pixel data.
- **Mesh is a clipmap**, not one mesh per region: `mesh_lods` (default 7) concentric
  rings of decreasing vertex density around the camera, `mesh_size` (default 48)
  controlling the LOD0 ring's quad count (`4*mesh_size + 2` quads/side). This is where
  Terrain3D's LOD actually comes from — it is unrelated to region granularity and
  needs no per-cell LOD mesh of our own.
- **Control map**: one `uint32` per pixel — 5 bits base texture ID (0–31), 5 bits
  overlay texture ID (0–31), 8 bits blend weight (0–255, base↔overlay), 4 bits UV
  angle, 3 bits UV scale, plus hole/navigation/autoshader flags. **Only two texture
  IDs are ever blended at a single pixel** (base + overlay via one blend scalar) —
  the "up to 32 textures" figure is the size of the global texture *list* (asset
  slots), not the number of layers active at any one point. This is a real
  compatibility constraint against FNV's `LAND` format — see below.
- **Runtime API is real and scriptable**, not editor-only: `add_region_blank(location:
  Vector2i)` / `add_region_blankp(global_position: Vector3)` create a region;
  `import_images(images: Array[Image], global_position, offset, scale)` bulk-writes
  height/control/color data; `set_height()`/`set_control()`/`set_control_base_id()`/
  `set_control_overlay_id()`/`set_control_blend()` write individual pixels;
  `update_maps()` must be called afterward to regenerate the GPU-side texture arrays
  the shader reads (this looks like the main-thread-only, batchable-cost operation in
  this pipeline — same category of concern as this project's own `RenderingServer`
  calls in `direct_geometry_batch.cpp`).
- **Instancer** (grass/foliage): editor-painted by default, but also has a real
  code-driven path — `Terrain3DInstancer.add_multimesh()`/`add_transforms()` — backed
  by `MultiMesh`, culled in 32×32m cells, with instance transforms persisted in the
  region files.
- **Collision** is a built-in `Terrain3DCollision` subsystem (`collision_mode`,
  `collision_layer/mask`, etc.), separate from our own NIF-derived
  `ConcavePolygonShape3D` collision path — needs independent verification (see open
  questions).

## FNV's terrain data model, as currently parsed (recap)

- `LAND.VHGT`: one `float32` offset + 33×33 row-major `int8` deltas, ×8-Gamebryo-units
  scale on both (see `esm_file.cpp`'s `get_land_data()` — real bug-fixed decode,
  documented in `phases/1/04-exterior-cell-terrain.md`). Vertex spacing is 128
  Gamebryo units = **128/70 ≈ 1.8286 m** (`native/src/common/units.h`'s
  `kGamebryoUnitsToMeters`), NOT 1 m.
- `LAND.BTXT`: one base `LTEX` FormID per quadrant (4 quadrants/cell, 17×17 vertices
  each). **Currently the only texture data actually read.**
- `LAND.ATXT`/`VTXT`: additional per-quadrant texture layers (`ATXT` names an extra
  `LTEX` + which quadrant/layer) with `VTXT` giving per-vertex opacity over that
  quadrant's 17×17 sub-grid. **Confirmed present in real data** (per
  `esm_types.h`'s `LandData` comment) but **never decoded** — `get_land_data()`
  explicitly skips them. The real per-cell layer count (2? 3? more?) has never been
  measured.
- `LTEX` → `TXST` → `.dds` path is resolved (`resolve_ltex_texture_path()`), one
  indirection deeper than `STAT.MODL`. No dedicated grass field has been located or
  parsed on `LTEX`/`TXST` yet — unconfirmed whether FNV's `LTEX`/`TXST` records carry
  any grass-density data at all (Bethesda-family engines have historically driven
  grass from a texture-associated record in some titles; this has **not** been
  verified against FNV's own real records in this project).
- Cell size: 4096 Gamebryo units = **4096/70 ≈ 58.514 m** per side, 32 grid intervals
  (33 vertices, matching `VHGT`).

## Compatibility mapping and gaps

| FNV concept | Terrain3D concept | Fit |
|---|---|---|
| `VHGT` 33×33 heightmap, 1.8286 m spacing | Height-map `Image` per region, `vertex_spacing` config | **Good, with a spacing decision** — see below |
| Cell = 32×32 grid intervals | Region = `region_size`×`region_size` pixels | **Good if `region_size` is a whole multiple of 32** (see below) |
| `BTXT` base texture per quadrant (17×17 verts) | Control map base texture ID per pixel | **Good** — strictly finer-grained than our current per-quadrant flat assignment (quadrant-uniform BTXT can be written as a uniform block of control-map pixels) |
| `ATXT`/`VTXT` additional layers, per-vertex alpha, N layers/quadrant | Control map: exactly 2 layers (base+overlay) blended per pixel, one scalar weight | **Gap, now measured.** Real census (see below): 85% of quadrants use 0 additional layers (`BTXT` alone fits perfectly), but a real tail goes up to 6 additional `ATXT` layers in a single quadrant (7 including `BTXT`'s base). A reduction heuristic is genuinely needed for that tail, not hypothetically. |
| Global set of `LTEX`/`TXST` ground textures used across the whole worldspace | Per-region texture *list*, capped at 32 slots | **Real gap, closed by real data.** 94 distinct textures game-wide, 80 in `WastelandNV` alone. At `region_size = 256` a realistic concurrently-resident neighborhood (a region + its 8 neighbors) exceeds 32 in 45% of the worldspace's regions, worst case 49 — but at `region_size = 64`, that same realistic check **never exceeds 32 anywhere in the real worldspace** (worst case 24). Chosen design: `region_size = 64` + a 31-slot LRU eviction pool (safety net, not load-bearing per the numbers) + a reserved pink "missing texture" fallback slot for genuine overflow. See below. |
| Per-cell terrain load/unload (current `WorldStreamer` granularity) | Per-region load/unload (regions span many cells) | **Architecture mismatch** — see "Streaming integration" below |
| No terrain LOD (current system) | Clipmap LOD, built-in | **Pure win**, no FNV-side data needed — Terrain3D generates its own LOD from the height data, unlike 2.12's object LOD which needed Bethesda's own `_lod.nif` companion meshes |
| Grass/scatter | Instancer, editor-painted or `add_transforms()`-driven | **Real match, now confirmed.** `LTEX.GNAM` is a real FormID field referencing a `GRAS` record (52/89 base-game `LTEX` records have one set); `GRAS.DATA` carries real density/slope/water/jitter/wave parameters and `GRAS.MODL` a real grass mesh path — see below. This maps directly onto per-texture-ID procedural scattering via `Terrain3DInstancer.add_transforms()`, keyed off the control map's own base/overlay texture ID — i.e. the same data-driven design the original engine used, not a new one. |
| `ConcavePolygonShape3D` terrain collision (current, works, but built on a documented `HeightMapShape3D` failure — see `phases/1/04-exterior-cell-terrain.md`) | Built-in `Terrain3DCollision` | **Needs independent re-verification** — if `Terrain3DCollision` uses a heightmap-shaped collider internally, the same failure mode that made us abandon `HeightMapShape3D` in 1.4 could resurface. Root cause of that failure was never fully diagnosed (worked around, not fixed), so it isn't safe to assume it won't recur here. |

### Heightmap spacing decision

Two real options, not yet chosen:

1. **Set `vertex_spacing = 128/70 ≈ 1.8286`** so Terrain3D's native pixel grid aligns
   exactly with Bethesda's own 128-unit grid, cell-for-cell, no resampling
   (`region_size` must be evenly divisible by 32 for clean cell alignment — 64→2
   cells, 128→4, 256→8, 512→16, 1024→32 cells/side all divide evenly; 2048→64). This
   avoids ever interpolating/resampling real height data, at the cost of Terrain3D's
   own docs nominally expecting ~1 px/m (this is explicitly supported as a config
   knob, not a hidden assumption, per the docs pulled above). **`region_size = 64`
   specifically** (2 cells/side) is the value the texture-budget investigation below
   settled on — real measurement across three candidate sizes found it's the
   smallest one tested where a realistic concurrently-resident neighborhood (a
   region + its 8 immediate neighbors) never exceeds Terrain3D's 32-slot texture
   budget anywhere in the real worldspace (see "`LTEX`/`TXST` texture budget" under
   "Real-data findings" for the full three-way comparison). Both the cell-alignment
   requirement and the texture-budget requirement land on the same value
   independently — 64 divides evenly into 2 cells/side, satisfying the former, while
   being small enough to satisfy the latter with real margin.
2. **Resample to 1 px = 1 m** (`vertex_spacing = 1.0`) and interpolate FNV's 33×33 grid
   up to ~59×59 samples per cell. Matches Terrain3D's documented default/expectation
   more closely, but means interpolated (not authored) height values, and cell
   boundaries no longer land on whole-pixel region boundaries (58.514 is not an
   integer), which would fight the "region = whole number of cells" alignment above.

**Recommendation: option 1** — no resampling, cell-aligned regions, matches this
project's general bias toward using real authored data unmodified rather than
reprocessed/approximated data (per this project's own working style — see feedback
memory on verifying real data). This should be confirmed, not just assumed, once a
spike (implementation step 2 below) actually renders a real region and checks it
against the existing per-cell terrain for a visual/metric match.

## Real-data findings (closes open questions 1–3, see below)

Scanned via `native/tools/terrain_census.cpp` against `FalloutNV.esm` + all nine
shipped DLC/bonus-pack `.esm` files in `fresh_nv_copy/Data/`. Build with
`native/tools/build_terrain_census.sh`, then run with a list of `.esm` paths as
arguments, e.g.:

```
native/tools/terrain_census fresh_nv_copy/Data/FalloutNV.esm fresh_nv_copy/Data/DeadMoney.esm \
  fresh_nv_copy/Data/HonestHearts.esm fresh_nv_copy/Data/OldWorldBlues.esm \
  fresh_nv_copy/Data/LonesomeRoad.esm fresh_nv_copy/Data/GunRunnersArsenal.esm \
  fresh_nv_copy/Data/CaravanPack.esm fresh_nv_copy/Data/ClassicPack.esm \
  fresh_nv_copy/Data/MercenaryPack.esm fresh_nv_copy/Data/TribalPack.esm
```

Output is deterministic (pure read of shipped game files) — not committed, regenerate
by re-running; the tool's source is what's committed.

### `ATXT`/`VTXT` layering

- 42,474 `LAND` records scanned across all worldspaces (base + DLC).
- 7,411 cells (17.4%) have at least one `ATXT` layer beyond `BTXT`'s base.
- Per-**quadrant** (the number that actually matters, since Terrain3D's control map
  blends per-pixel and each of a cell's 4 quadrants paints independently): of 169,892
  quadrants scanned, 144,427 (85.0%) have **zero** additional layers — `BTXT` alone is
  already a perfect fit for those. The remainder decays smoothly out to a real max of
  **6** additional `ATXT` layers stacked in a single quadrant (2,754 quadrants hit
  that max), i.e. up to **7 simultaneous layers at one point** including `BTXT`'s own
  base — never the naive "24" that summing across all 4 quadrants of a cell suggests
  (that number is real too, but it's spread across 4 independently-painted quadrants,
  not stacked at one point).
- This confirms the 2-layer (base+overlay) control-map gap is real for the ~15% of
  terrain that isn't flat-`BTXT`, but bounds the worst case concretely: a reduction
  heuristic needs to go from at most 7 layers down to 2, not an unbounded number, and
  only needs to do meaningful work for a minority of quadrants. A reasonable starting
  heuristic (not yet implemented): keep the two layers with the highest *total*
  `VTXT` opacity mass within that quadrant as control-map base/overlay, and treat any
  further layers as a documented, acknowledged lossy approximation — the same kind of
  scope cut `phases/1/04-exterior-cell-terrain.md` already made for `BTXT`-only.

### `LTEX`/`TXST` texture budget

- 94 distinct `LTEX` FormIDs referenced by any `LAND` `BTXT`/`ATXT` across the whole
  game (base + all DLC combined) — over Terrain3D's 32-slot global list if treated as
  one flat pool.
- **But scoped per-worldspace** (see "Streaming integration" below for why that's the
  right scope — the player is only ever in one worldspace's terrain at a time, so one
  `Terrain3D` node/texture-list per worldspace is the natural fit), the picture is much
  narrower:
  - `WastelandNV` (the main Mojave map, 16,388 `LAND` cells): **80 distinct
    textures** — genuinely over budget, 2.5×.
  - Every other worldspace in the game fits under 32 on its own. The next-largest is
    `NVDLC03BigMT` (Old World Blues, 4,096 cells) at 27 — close, but under. All
    other DLC/interior-test worldspaces (`NVDLC02ZionCanyon`, `TheStripWorldNew`,
    `Lucky38World`, `WastelandNVmini`, the Freeside sub-maps, the Dead Money Villa
    sub-maps, the Lonesome Road sub-maps, etc.) range from 1–19.
  - **The 32-slot gap is specifically a `WastelandNV` problem**, not a whole-game
    problem. This materially changes the design: no global texture-list partitioning
    scheme is needed, only a `WastelandNV`-specific mitigation.
- **Resolved: a real, working design, closed by checking region size against
  realistic concurrent residency rather than a single isolated region.** Extended
  `terrain_census.cpp` several more times against real data:
  1. **Dedupe by resolved `TXST`→`.dds` path, not raw `LTEX` FormID.** Real result:
     `WastelandNV`'s 80 distinct `LTEX` FormIDs resolve to only **64 distinct texture
     paths** — 11 real duplicate groups found (e.g. 4 separate `LTEX` FormIDs
     `0x02FAE3`/`0x061EAE`/`0x063A8D`/`0x104A46` all point at
     `Landscape\ScrubDirtCanyon01.dds`; likely gameplay-material variants — footstep
     sound, etc. — sharing one visual). Real, but not sufficient alone: 64 is still
     2× over the 32-slot budget.
  2. **A single resident region is not a realistic scenario.** A streamer has to keep
     a region's neighbors resident too — a player standing near a region boundary
     needs both sides loaded, the same way `WorldStreamer` already keeps a radius of
     neighboring *cells* resident, not one cell at a time. So the number that
     actually matters is the **union of a region's texture set with its 8 immediate
     neighbors** (a 3×3 block — a realistic minimum concurrently-resident set for
     smooth streaming across any boundary), not any single region's own count in
     isolation. First measured at `region_size = 256` (8 cells/side) and found a real
     gap: worst-case union of 49 textures, with 49 of 110 covered regions (45%)
     exceeding 32 — smaller than the naive worldspace-wide 64/80, but still a real,
     frequent problem at that region size.
  3. **Smaller regions close it — measured directly, not assumed.** The 3×3-union
     figure isn't fixed; it scales with how much real-world area 9 regions cover,
     which shrinks as `region_size` shrinks (a `region_size = 256` region is
     ~468m/side at the cell-aligned `vertex_spacing`, so its 3×3 neighborhood spans
     ~1.4km of genuinely diverse Mojave terrain — most of the budget problem was an
     artifact of that region size being too coarse, not an inherent property of the
     data). Measured across three region sizes, all still whole multiples of 32 for
     cell alignment:

     | `region_size` | cells/region | max in ONE region | max 3×3-neighbor union | regions w/ union > 32 |
     |---|---|---|---|---|
     | 256 | 8 | 27 | 49 | 49 / 110 (45%) |
     | 128 | 4 | 20 | 38 | 6 / 363 (1.7%) |
     | **64** | **2** | **16** | **24** | **0 / 1298 (0%)** |

     At `region_size = 64`, the realistic concurrently-resident neighborhood **never
     exceeds 32 anywhere in the real worldspace** — worst case 24, with 8 slots of
     real headroom. Confirms the intuition that ground-texture diversity really is
     locally low across the Mojave; the earlier 256-sized measurement was simply
     looking at too large an area at once.
  - **Chosen design** (real, concrete, ready to implement — not just options to
    weigh anymore):
    1. **`region_size = 64`** — real data shows this alone keeps every realistic
       concurrent-residency case under budget with margin, no lossy reduction or
       addon patching needed anywhere in the game's real terrain data.
    2. **LRU slot eviction as a safety net, not the primary defense.** Terrain3D's
       control map is a real, mutable per-pixel value
       (`set_control_base_id()`/`set_control_overlay_id()`, confirmed in the runtime
       API above), so slots are tracked as a 31-entry LRU pool (see next point for
       why 31, not 32): when a currently-unreferenced-by-any-resident-region texture's
       slot is needed for a newly-streamed-in one, evict the least-recently-used
       entry and repaint any still-resident region whose control-map IDs pointed at
       it. Since `region_size = 64` means the real worst case never exceeds 24, this
       should rarely or never actually trigger in normal play — it exists to survive
       cases outside the 3×3-neighbor approximation (DLC content not covered by this
       census, a player standing exactly on a 4-region corner, a future change to
       streaming radii) rather than to carry routine load, so its real runtime cost
       (folds into open question 6 below) matters less than it would if it were
       load-bearing.
    3. **Reserve slot 31 as a fixed "missing texture" fallback** (solid pink, or
       another unmissable debug color) — any texture that can't be assigned a real
       slot because the LRU pool is genuinely full renders as pink instead of
       crashing, silently reusing the wrong texture, or blocking region construction.
       Makes a real overflow immediately visible in-game (and trivially greppable in
       a screenshot/bug report) rather than a silent correctness bug. Costs one slot
       (31 usable instead of 32), which the `region_size = 64` numbers above already
       have comfortable headroom against (worst case 24 of 31).
  - **Worth being honest about the PS3 comparison** — the original engine's own
    terrain shader binds textures more directly per quadrant/material rather than
    through one shared, fixed-size 32-slot indexed palette; the "32 slots, 5-bit
    control map ID" constraint is specific to Terrain3D's own on-disk/editor data
    format choice (a compact packed `uint32` designed for hand-painting), not a
    rendering limit New Vegas itself had to solve on PS3. This design doesn't
    replicate whatever the original did — it sidesteps the constraint Terrain3D
    itself introduces, informed by the real measured locality of the actual game
    data.

### Grass

- **Confirmed real, data-driven grass exists in the ESM.** `LTEX.GNAM` is a 4-byte
  FormID subrecord present on 52 of 89 base-game `LTEX` records (58 more across DLC,
  ~all following the same pattern) — every example sampled with `GNAM` set has an
  editor ID ending in `...Grass` (e.g. `ChemicalBarrenWastes01Grass`), and it resolves
  to a `GRAS` record (24 `GRAS` records in the base game; 4 more in Honest Hearts, 1
  more in Old World Blues — none in the other DLCs).
- `GRAS.DATA` (32 bytes, real layout, confirmed via
  [fopdoc GRAS](https://tes5edit.github.io/fopdoc/FalloutNV/Records/GRAS.html) and
  cross-checked against the real 32-byte subrecord size found in every sampled
  record): `density` (u8), `min_slope`/`max_slope` (u8 each), `unit_from_water_amount`
  (u16), `unit_from_water_type` (u32), `position_range`/`height_range`/`color_range`/
  `wave_period` (float32 each), `flags` (u8). `GRAS.MODL` is a real grass-clump `.nif`
  model path, same subrecord convention as `STAT.MODL`.
- This closes open question 3 with a concrete design: FNV's own grass system is
  already exactly "per-texture procedural scatter with density/slope/water
  filtering," which maps directly onto `Terrain3DInstancer`'s code-driven
  `add_transforms()` path keyed off which `LTEX` (i.e. which control-map texture ID)
  is painted at a given point, replicating the original engine's own data model
  instead of inventing a new one. Concretely: for every `LTEX` with `GNAM` set, when
  building/updating a region's control map, also scatter that `LTEX`'s `GRAS.MODL`
  mesh across the area painted with that texture ID, at `GRAS.DATA`'s density,
  filtered by the same slope/water/height rules FNV itself defines. Not yet
  implemented — this is a design conclusion, not a working feature — but the "no
  known data source" uncertainty from the first draft of this doc is resolved.

### Streaming integration

The core tension: `WorldStreamer` streams **cells** (58.5 m squares) on a tunable
radius; Terrain3D's natural unit is a **region**. Note this is smaller than earlier
drafts of this doc assumed — the texture-budget finding above settled on
`region_size = 64` (2 cells/side, ~117 m), not the originally-proposed 256/512, so
"region" here is closer in scale to a small handful of cells than "hundreds of
meters square." That also means more, smaller regions overall (1,298 covering
`WastelandNV` vs. 110 at `region_size = 256`), so option A's "rarely unloaded, coarse
residency radius" premise still holds directionally but with more individual
region objects churning at the boundary — worth factoring into the real profiling
pass in open question 6. Two architectural options:

- **A. Decouple terrain residency from object residency.** Load a whole region (many
  cells) as soon as the player's position or any in-radius cell first touches it,
  keep it resident across a *coarser* radius than full object/collision detail (since
  the clipmap mesh is cheap at distance — that's the entire point of using it), and
  only call the region-removal API once the player is a full region-size or more away.
  This matches Terrain3D's own intended usage pattern (built for large, mostly-resident
  terrains) rather than fighting it with frequent create/destroy churn. **Recommended
  starting point.**
- **B. Keep per-cell granularity by writing into sub-regions of an already-resident
  region as cells individually stream in/out**, leaving not-yet-streamed sub-areas of
  a region blank/flat. Fine for *loading* (per-cell `import_images()` calls at the
  cell's pixel offset within its region), but Terrain3D has no documented API for
  "clear just this cell's slice of a region" — unloading would mean either accepting
  stale/blank patches are wrong-but-invisible-behind-something-else, or falling back
  to (A)'s region-level unload anyway. This suggests (A) is unavoidable at the
  *unload* boundary even if (B) is used for progressive loading.

Practical read: **use (A)**, with per-cell `import_images()` calls (each cell writing
its own 32×32-pixel slice, positioned via `global_position`) filling a region
progressively as its covering cells individually finish streaming — this reuses the
existing progressive-reveal philosophy from 2.12's stutter fixes (`_construct_results()`
already yields per-object across frames; the same per-cell "one `import_images()` +
one `update_maps()` call per frame, spread across N frames" pattern applies directly)
rather than blocking on decoding every cell in a region before any of it appears.

### Coexistence / migration plan

Do not delete `GamebryoTerrainBuilder` before the Terrain3D path is validated. Land
this behind an explicit switch (e.g. a `WorldStreamer` export or scene-level toggle)
so the existing, working, in-play-validated system stays available as a fallback and
an A/B reference for visual/collision comparison during implementation.

## Open questions requiring real-data research (block implementation until answered)

Per this project's own established discipline (verify against real data, don't trust
docs/memory alone — see `phases/1/04-exterior-cell-terrain.md`'s two documented
decode-order bugs, both only found by comparing against real REFR/physics data):

1. ~~Real `ATXT`/`VTXT` layer counts across the Mojave.~~ **Answered** — see
   "Real-data findings" above: 85% of quadrants need no reduction at all; worst real
   case is 7 simultaneous layers at one point, needing a defined (not yet
   implemented) priority-by-opacity reduction to Terrain3D's 2.
2. ~~Real distinct-`LTEX`/`TXST` count across the whole worldspace.~~ **Fully
   resolved** — see "Real-data findings" above: 94 globally, 80 in `WastelandNV`
   alone, but scoped to realistic concurrent residency (a region + its 8 neighbors)
   at `region_size = 64`, the real measured max is 24 — never exceeds Terrain3D's
   32-slot budget anywhere in the real worldspace. Design chosen: `region_size = 64`
   + a 31-slot LRU eviction pool as a safety net (not load-bearing per the real
   numbers) + a reserved pink "missing texture" fallback slot for genuine overflow.
   Remaining work is implementation, not further open design questions — the LRU
   pool's real runtime cost still needs profiling (folds into open question 6).
3. ~~Does FNV encode grass/scatter placement anywhere in the ESM at all?~~
   **Answered** — see "Real-data findings" above: yes, `LTEX.GNAM` → `GRAS` with real
   density/slope/water/jitter data and a real mesh path. Design conclusion reached
   (map onto `Terrain3DInstancer.add_transforms()` keyed off control-map texture ID);
   **still open**: actually wiring this up is unimplemented, and `GRAS.flags`' bit
   meanings haven't been decoded yet (fopdoc's `GRAS` page wasn't checked for this —
   needs the same real-data-first treatment before assuming a specific bit is e.g.
   "vertex lighting").
4. **Terrain3D's actual Godot 4.7.1 compatibility** — confirm current release
   supports 4.7.x specifically (not just "Godot 4"), and confirm it coexists cleanly
   as a second GDExtension alongside this project's own native module (build/load
   order, no symbol/version conflicts) before committing design decisions to it.
   **Still open** — not investigated in this pass.
5. **Re-verify `HeightMapShape3D`/heightmap-collider behavior on this engine build**
   before trusting `Terrain3DCollision`'s built-in path. 1.4's original
   `HeightMapShape3D` failure was worked around (switched to
   `ConcavePolygonShape3D`), never root-caused — if Terrain3D's built-in collision
   uses the same underlying primitive, the same failure could resurface and needs its
   own physics drop test (same methodology as `test_terrain_collision.gd`). **Still
   open.**
6. **Real `import_images()`/`update_maps()` cost per cell/region**, profiled the same
   way 2.9–2.12's construction costs were (real headless timing, not assumption) —
   this sits in the same streaming hot path that 2.12's two stutter bugs came from,
   and `update_maps()` in particular sounds like a batchable-but-not-free main-thread
   operation worth budgeting before it's built into the streamer. **Still open** —
   needs the actual addon installed first (blocked on question 4).

## Proposed implementation sequence (not yet authorized — for after this doc is reviewed)

Small, independently testable steps, matching this phase's established task-file
granularity rather than one large change:

1. ~~Add the Terrain3D addon/GDExtension to the project; confirm it builds/loads
   alongside the existing native module on Godot 4.7.1.~~ **Done** — vendored as
   `native/terrain3d` (submodule, pinned to `v1.0.2-stable`), built, copied into
   `project/addons/terrain_3d/`, enabled via `project.godot`, confirmed loading
   cleanly alongside `nv_engine` via a real headless editor pass. **Answers open
   question 4**: yes, it's compatible — Terrain3D's own nested `godot-cpp` was left
   at its own older pin rather than forced to match our newer one (forcing it broke
   compilation; GDExtension's ABI is stable across engine minor versions regardless).
   See `native/README.md`'s Dependencies section for the full story.
2. ~~Spike: import one real cell's (Goodsprings, `(-17, 0)`) `VHGT` heightmap into a
   single Terrain3D region at `vertex_spacing = 128/70`; visually and numerically
   compare against the current `GamebryoTerrainBuilder` output.~~ **Done** —
   `project/tests/test_terrain3d_spike.gd`/`.tscn`. Built a `FORMAT_RF` height
   `Image` directly from `get_land_data()`'s real heights, imported via
   `Terrain3DData.import_images()` at `vertex_spacing = 128/70`, `region_size = 64`
   (the value settled on in "Real-data findings" below). **Numeric result: bit-exact
   round-trip** — 9 sample points (all 4 corners, center, and 4 interior points)
   read back via `Terrain3DData.get_height()` with **0.000000m error** against the
   source `LandData.heights` array (Terrain3D snaps exactly-on-vertex queries to the
   stored pixel rather than interpolating, confirmed by reading
   `terrain_3d_data.cpp`'s `get_height()` — no float noise from bilinear blending).
   **Visual result**: a real, non-flat, gently undulating ridge across the imported
   patch (screenshot at `/tmp/nv_test_screenshots/terrain3d_spike_goodsprings.png`,
   not committed) — the surrounding checkered plane and sharp cliff at the patch's
   edges are Terrain3D's default "no data here" flat plane at height 0, an expected
   artifact of importing one isolated cell with nothing painted around it, not a bug
   (the numeric check already proves the data itself is correct). Coordinate
   convention note: this test uses Terrain3D's own native image-column→+X,
   image-row→+Z mapping (confirmed by reading `Terrain3DData::get_pixel()`) rather
   than inheriting `GamebryoTerrainBuilder`'s reflected-Z convention — no reason to
   carry that convention forward into a new placement scheme.
3. ~~Extend `get_land_data()` to actually decode `ATXT`/`VTXT`; write a standalone
   census tool to answer open questions 1 and 2 across the full worldspace before any
   texture-painting code is written.~~ **Done** — `native/tools/terrain_census.cpp`,
   see "Real-data findings" above. `get_land_data()` itself is still `BTXT`-only;
   the census tool decodes `ATXT`/`VTXT` independently, read-only, without changing
   that shared code path yet — extending `get_land_data()`/`LandData` for real is
   still step 4's work, informed by these numbers rather than done blind.
4. Implement control-map painting for the base-texture-only case first (parity with
   current scope, ~85% of quadrants need nothing more than this), then extend
   `get_land_data()`/`LandData` to carry real `ATXT`/`VTXT` data and implement the
   opacity-priority 7→2 layer reduction for the remaining ~15%, using the real
   distribution measured above. Implement texture-slot assignment as the chosen
   `region_size = 64` + 31-slot LRU pool + pink-fallback-slot design from
   "`LTEX`/`TXST` texture budget" above.
5. Physics drop test against `Terrain3DCollision` (answers open question 5); fall back
   to keeping our own `ConcavePolygonShape3D` collision layered on top of Terrain3D's
   render-only output if it fails, rather than blocking the whole integration on it.
6. Wire into `WorldStreamer` per the region-residency design above (option A); real
   before/after profiling of streaming settle time and frame stability during
   traversal, same discipline as 2.8–2.12.
7. Grass/instancer work — separate follow-on (design now settled, see "Real-data
   findings" above: `LTEX.GNAM` → `GRAS` → `Terrain3DInstancer.add_transforms()`),
   explicitly not bundled into the core terrain swap.
8. Once visually/behaviorally validated in real play (same bar 2.12 used — "good
   enough, real play verified"), remove the old `GamebryoTerrainBuilder` path and its
   `WorldStreamer` toggle.

## Explicit non-goals for this task

- Grass/scatter placement — blocked on open question 3, tracked as a follow-on, not
  bundled into the core swap.
- Any change to non-terrain streaming (object/collision loading, LOD from 2.12) beyond
  what's needed to call into the new terrain path instead of the old one.
- Full N-layer-accurate texture reproduction if the real `ATXT` layer census (open
  question 1) comes back higher than what a 2-layer control map can represent well —
  a documented, acknowledged approximation is acceptable here the same way 1.4 already
  accepted "base texture only, no blending" as a real scope cut.
