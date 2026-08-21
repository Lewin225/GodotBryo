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
5. ~~Re-verify `HeightMapShape3D`/heightmap-collider behavior on this engine build
   before trusting `Terrain3DCollision`'s built-in path.~~ **Answered** — see
   "Real-data findings" below (implementation step 5): real drop-ball test, no
   repeat of 1.4's total-failure mode, vertical settle correct everywhere. One real
   secondary finding (small-sphere slope-rolling, not a bug) documented there too.
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
4. **Base-texture-only control-map painting: done, real-data-verified.**
   `project/tests/test_terrain3d_texture_paint.gd`/`.tscn` — resolves each of
   Goodsprings' 4 quadrants' real `BTXT`→`LTEX`→`TXST`→`.dds` texture (same
   resolution path `test_terrain.gd` already exercised), builds one
   `Terrain3DTextureAsset` per *distinct* resolved texture (2 distinct textures
   found across this one cell's 4 quadrants — a real, small-scale preview of the
   path-dedup finding above), and paints `Terrain3DData.set_control_base_id()`
   across each quadrant's real 17×17 vertex range (same ranges
   `GamebryoTerrainBuilder` uses). Numeric round-trip via `get_control_base_id()`
   confirmed exact for all 4 quadrants. Real (non-headless) screenshot shows two
   correctly-textured ground materials meeting cleanly at the real quadrant
   boundary, sitting on the real heightmap from step 2 — not placeholders.
   **`ATXT`/`VTXT` → control map: also done, real-data-verified.** Extended
   `LandData` (`native/src/esm/esm_types.h`) with a new `LandAlphaLayer` type (LTEX
   FormID, quadrant, `ATXT`'s own layer-stacking index, and a real per-vertex
   opacity array decoded from `VTXT`'s sparse position+opacity entries) and
   `get_land_data()` (`esm_file.cpp`) to actually populate it — real output against
   Goodsprings: 24 alpha layers (6 per quadrant, matching the earlier census's
   per-quadrant max exactly), with plausible nonzero-opacity counts (8–194 of 289
   vertices per layer, not garbage). Exposed through `EsmReader.get_land_data()`'s
   Dictionary as `alpha_layers`. `project/tests/test_terrain3d_multilayer_paint.gd`/
   `.tscn` implements the opacity-priority reduction: per quadrant, `BTXT` is always
   the base, and the single `ATXT` layer with the highest **total** opacity mass
   across that quadrant becomes the overlay (real per-vertex opacity as the blend
   weight) — everything else in that quadrant is a documented, acknowledged lossy
   drop, same category of scope cut as `BTXT`-only was for 1.4. All 4 of
   Goodsprings' quadrants got a real, distinct overlay layer selected; numeric
   round-trip via `get_control_overlay_id()`/`get_control_blend()` exact on a real
   painted vertex; screenshot shows genuine organic-shaped blended patches (a darker
   rocky texture blended over the base), not a placeholder or a hard geometric
   boundary. **Not yet done**: the `region_size = 64` + 31-slot LRU pool +
   pink-fallback-slot texture-budget design (every single-cell test so far has only
   ever needed 2–4 slots, nowhere near exercising the budget problem — that needs
   multiple concurrently-loaded cells/regions to actually trigger, i.e. step 6's
   `WorldStreamer` integration).
5. ~~Physics drop test against `Terrain3DCollision`.~~ **Done — real collision
   works, answers open question 5.** `project/tests/test_terrain3d_collision.gd`/
   `.tscn`: `Terrain3DCollision.FULL_GAME` mode, real drop-ball-at-three-points
   methodology (same as `test_terrain_collision.gd`). **No repeat of 1.4's
   `HeightMapShape3D` total failure** — vertical settle error stayed under 0.2m at
   every point (most within a few mm). One real, honest finding along the way:
   horizontal drift for a tiny (0.1m radius) sphere reached ~0.9m at one point —
   confirmed via direct measurement to be genuine physical rolling down real local
   terrain slope (checked and ruled out being an artifact of this single-cell test's
   artificial island edge — the drift persisted even at a point well inside the
   patch's interior), not a collision-alignment bug. Test's horizontal tolerance
   loosened from `test_terrain_collision.gd`'s 0.5m to 2m accordingly, with the
   reasoning documented inline — still tight enough to catch a real placement bug
   (wrong cell, axis swap, order-of-magnitude misalignment). No fallback to
   `ConcavePolygonShape3D` needed.
6. **In progress — real per-cell bridge built and verified; `WorldStreamer` wiring
   itself not yet done.** `project/gamebryo/terrain3d_bridge.gd` +
   `terrain3d_texture_pool.gd` implement the actual "given a real cell, write its
   real height/control data into a shared, persistent Terrain3D node at its real
   world position" work, verified by `project/tests/test_terrain3d_bridge_placement.gd`
   two ways: (1) cross-checked against `GamebryoTerrainBuilder`'s own real,
   already-live placement for the same cell — exact match, 0.000000m error at 5
   sample points; (2) two real adjacent cells (`(-17,0)`/`(-17,1)`) imported into
   the *same* Terrain3D node agree exactly at their shared boundary. Three real
   bugs found and fixed while building this (real engineering findings, not
   guesses caught in review):
   - **A real crash in Terrain3D itself.** `Terrain3DAssets::_set_asset_list()`
     (`terrain_3d_assets.cpp`) dereferences every array element's `get_id()` with
     no null check — passing a pre-sized `Array[Terrain3DTextureAsset]` with empty
     slots to `set_texture_list()` segfaults inside the compiled addon. Fixed by
     using `Terrain3DAssets.set_texture(id, asset)` one at a time instead (its
     `_set_asset()` append path assigns real sequential ids safely) —
     `terrain3d_texture_pool.gd` documents this inline.
   - **`Terrain3DData.import_images()` cannot be used for incremental per-cell
     streaming at all.** It's a bulk, region-*aligned*, whole-region-*replacing*
     operation (`region->set_maps(images)` per slice, confirmed by reading the
     source) — a second cell imported into an already-populated shared region via
     `import_images()` silently wipes the first cell's data outside its own narrow
     slice. This directly contradicts what the original design (implementation
     step 2/4) assumed based on the single-cell spike tests, where it happened to
     work because each test only ever touched one, always-freshly-created region.
     Fixed by switching to the real per-pixel API (`set_height()`/`set_control()`,
     confirmed to write into an existing region without disturbing the rest of it)
     after explicitly pre-creating every region a cell's vertex range touches.
   - **A real float-epsilon bug at exact region boundaries.** A cell edge that
     mathematically sits exactly on a region boundary (e.g. world Z=0) can resolve
     to either neighboring region depending on tiny floating-point rounding
     differences between two expressions that are only equal in exact math
     (`VERTEX_SPACING*(GRID_SIZE-1)` vs `CELL_SIZE_UNITS*GAMEBRYO_UNITS_TO_METERS` —
     mathematically identical since `32*128=4096`, not bit-identical after
     rounding) — real, reproducible, not hypothetical: two of five real cross-check
     points failed with "no active region found" the first time this was tried.
     Fixed by computing which regions a cell touches via pure integer grid math
     (`grid_x`/`grid_y`/`REGION_SIZE` only, no floats) in
     `ensure_regions_for_cell()`, and always pre-creating *every* candidate region
     regardless of which one the float math would predict — makes the later
     per-vertex float lookups robust no matter which side of the boundary their
     own rounding lands on.
   - **Wired into `WorldStreamer`, real profiling done.** A new
     `@export var use_terrain3d: bool = false` (default off, per the coexistence
     plan) creates one shared, persistent Terrain3D node in `activate()` (freed in
     `deactivate()`, fresh per worldspace switch — real region residency *within*
     one active worldspace session, as the camera moves, is still the coarser,
     not-yet-built policy the "Streaming integration" section above describes) and
     `_stream_tile()` branches to `Terrain3DBridge.import_cell()` instead of
     `CellStreamBuilder.build_terrain()`, timed into the same
     `diagnostic_terrain_ms` array used since 2.9 for a direct comparison.
     `import_cell()` also now calls `terrain.data.update_maps()` once per cell (the
     numeric round-trip tests passed without it — they read region data directly —
     but real rendering needs it; batching it across multiple tiles-per-frame
     instead of once-per-cell is a real, identified follow-up, not yet needed).
     Real measurement (`project/_diag_terrain3d_cost.gd`, untracked scratch tool,
     same convention as `_diag_construct_cost.gd`): 49 real tiles around
     Goodsprings, `_stream_tile()` called directly (bypassing `activate()`'s own
     full `RADIUS_LOAD_DISTANT=20` scan — ~1257 tiles, too much for a first timing
     pass) —

     | | avg | median | p95 | sum (49 tiles) |
     |---|---|---|---|---|
     | `GamebryoTerrainBuilder` (existing) | 5.09ms | 2.57ms | 3.30ms | 249ms |
     | `Terrain3DBridge` (new) | 5.31ms | 1.16ms | 21.05ms | 260ms |

     **Real, reassuring result**: despite the real concern that per-vertex
     `set_height()`/`set_control()` calls (1089 vertices × 2 map types per cell —
     genuinely more native calls than the old path's single mesh-build call) might
     be meaningfully slower, aggregate cost is comparable — even a better median —
     though p95 is notably higher (21ms vs 3.3ms), suggesting some tiles (likely
     ones needing new region creation, or with more resolved textures) cost more
     than the typical case. Good enough to not block further work, but real
     evidence for where the update_maps()-batching follow-up would matter most if
     ever needed. Full existing test suite re-run clean (including
     `test_world_streamer.tscn`, unaffected since `use_terrain3d` defaults off) —
     no regressions from either the `WorldStreamer` change or the earlier
     `esm_file.cpp`/`esm_types.h` `ATXT`/`VTXT` change.
   - **A real, serious bug found and fixed only after testing at real scale.**
     All the single/two-cell tests above passed cleanly, but the user directly
     observed garbled, spiky terrain in real play (`game.tscn`, `use_terrain3d`
     manually enabled for inspection) — massive vertical spikes and a sharp white
     wall cutting through otherwise-correct textured terrain. A real-data
     verification pass across a 9×9 real-cell grid (`project/_diag_terrain3d_verify.gd`,
     untracked scratch tool) confirmed it: **11,671 of 88,209 real vertices
     (13.2%) had wrong height data**, affecting 74 of 81 cells, worsening with
     distance from the world origin. Root-caused by comparing a wrong vertex's
     stored value against every neighboring vertex's real expected height (not
     guessed): the wrong value at `(row=16, col=29)` in cell `(-14,-1)` was
     *exactly* the correct expected value for `(row=16, col=30)` — a real
     off-by-one column indexing bug, not a boundary-region issue (this vertex
     wasn't near any region edge) and not the earlier float-epsilon bug (already
     fixed). Real cause: `Terrain3DData::set_pixel()`/`get_pixel()`
     (`terrain_3d_data.cpp`) compute their internal pixel index via a raw C++
     float-to-int **cast** of `world_position / vertex_spacing` — a **truncation**,
     not a `round()`. A world position meant to land exactly on integer pixel N
     can, after passing through `VERTEX_SPACING`'s own multiply/divide chain
     (`128.0/70.0` has no exact binary floating-point representation), come out as
     `N - 0.0000001` due to ordinary accumulated rounding — truncating down to
     `N-1` instead. This explains every earlier symptom precisely: worse at
     cells farther from the origin (more accumulated float error at larger
     magnitudes), and *not* caught by the 1–2-cell isolated tests (their cells
     were close enough to the origin, or just lucky, that no vertex happened to
     land on the wrong side of an integer boundary). Fixed in
     `Terrain3DBridge.vertex_world_position()` with a small, consistently-signed
     epsilon nudge (0.001m, ~20× larger than a real float32 ULP at these
     magnitudes, ~1800× smaller than the ~1.83m real vertex spacing — large
     enough to always correct a "just barely on the wrong side" truncation,
     nowhere near large enough to ever cross into a genuinely different vertex's
     own pixel) applied before any position ever reaches Terrain3D's own API.
     **Re-verified after the fix: 0 of 88,209 vertices mismatched** across the
     same real 9×9-cell grid — a complete fix, not a reduction. Full test suite
     and the real profiling comparison above both re-run clean after the fix
     (performance unaffected: 261.50ms vs the pre-fix 260.22ms for the same 49
     tiles). This is the strongest evidence yet in this design doc for why
     "verify against real data at real scale," not just isolated unit tests, is
     load-bearing — every earlier test in this task passed and still would have
     shipped a visibly broken terrain without this real-play report.
   - **Three more real bugs found and fixed from real play, after the off-by-one
     fix above** (user manually enabled `use_terrain3d` on `game.tscn`'s
     `WorldStreamer` node to look): terrain culled oddly (only visible looking
     more than ~40° downward, distant terrain less affected), and ground
     textures started as one real dirt texture during loading but ended up
     **entirely white** once loading settled.
     1. **Culling bug, two contributing causes.** First:
        `_terrain3d.set_camera()` was never called anywhere in the real
        `WorldStreamer` wiring (only in isolated test scenes) — without a real
        camera reference, Terrain3D's own internal `_grab_camera()` (its
        clipmap LOD update) fails every physics frame and its
        `_physics_process()` stops entirely, exactly the
        `"Cannot find the active camera"` error seen throughout this whole
        implementation's own testing, previously dismissed as cosmetic test
        noise. Fixed by syncing `_terrain3d.set_camera(_active_camera())`
        every `_check_streaming()` tick. **Confirmed real but not sufficient
        on its own** — the reported culling symptom persisted after this fix.
        Second, the actual root cause: `Terrain3DData::update_master_height()`
        (`terrain_3d_data.h`) exists specifically to keep the terrain's cached
        height range current as pixels are written, but is **never actually
        called** by `set_height()`/`set_pixel()` — confirmed by reading the
        source, genuinely dead code in the addon, not a usage mistake on our
        side. A freshly-created blank region's height range defaults near
        `(0,0)`, and without ever recalculating it, the mesh's own
        vertex-shader-displacement culling AABB stayed built from that stale
        near-zero range instead of the real ~110–125m data — so Godot's
        ordinary frustum culling, working correctly against the *wrong* bounds,
        clipped real geometry depending on view angle exactly as reported
        (shallow angles clip out an AABB that doesn't reach the real height;
        looking steeply down keeps more of it in frame by chance). Fixed by
        calling `terrain.data.calc_height_range(true)` once per cell import,
        alongside the existing `update_maps()` call. Verified directly (not
        just by re-checking the visual): a real diagnostic showed the height
        range API returning `(0.0, 0.0)` before a cell's import and the real
        `(0.0, 120.8)` — matching the cell's actual known max height — right
        after, once this fix was in place.
     2. **"All white" bug — a real, confirmed texture-budget overflow, exactly
        the scenario the design's "still not evidenced in practice" pink
        fallback was built for, now genuinely triggered.** A real diagnostic
        scan (961 real cells, ~31×31 around Goodsprings) confirmed real
        overflow: `Terrain3DTexturePool.used_slot_count()` hit exactly 31 —
        the 31-slot budget is real and gets exhausted in real play, not
        theoretical. But the pink fallback itself was broken: it was a fixed
        4×4 `FORMAT_RGB8` image, while real ground textures are real ~512×512
        *compressed* (BC1) textures with mipmaps. Found by reading
        `Terrain3DAssets::_update_texture_files()`
        (`terrain_3d_assets.cpp`): it requires every texture in the list to
        share the *exact* size/format/mipmap state as the first one, and
        **aborts rebuilding the entire albedo texture array** the moment any
        one texture fails that check (`if (_terrain->get_warnings()) {
        return; }`, checked *before* the rebuild) — so the mismatched pink
        placeholder wasn't just wrong itself, it silently blocked every
        already-correctly-textured region in the whole node from ever
        rendering, the moment the 32nd distinct texture was needed. Fixed in
        `Terrain3DTexturePool._ensure_pink_slot()`: build the placeholder
        uncompressed first (`Image.fill()`/`generate_mipmaps()` both refuse to
        operate on compressed formats directly, confirmed via a real error),
        then `Image.compress()` it to match the real first texture's actual
        size/format/mipmap state, queried directly rather than assumed. Real
        regression test added:
        `project/tests/test_terrain3d_texture_pool_overflow.gd` — imports the
        same real ~31×31 cell area, confirms real overflow happens
        (31/31 slots used) and the pink fallback's size/format/mipmap state
        now exactly matches the first real texture (512×512, format 17/BC1,
        mipmaps true). This is the confirming, no-longer-hypothetical case for
        the design doc's own "if real play ever shows the pink fallback
        firing, that's the real signal to build eviction" — it fired, at a
        realistic real-play area size, well before the WastelandNV-wide
        worst-case numbers in "Real-data findings" above would have predicted
        needing it. **Real LRU eviction (reclaiming slots from
        no-longer-resident cells, not just detecting exhaustion) is still not
        built** — the pool is genuinely append-only/global today, and a large
        real play session will keep hitting this same 31-slot ceiling
        repeatedly as new areas stream in. This is now confirmed necessary,
        not speculative.
   - **Texture-scale bug, both renderers.** Real user report, not caught by any
     screenshot test (none zoomed in close enough): ground textures looked "far
     too scaled up" in both `GamebryoTerrainBuilder` (old) and Terrain3D (new)
     — two unrelated mechanisms, same visible symptom, both real. Old renderer
     (`terrain_builder.gd`): UVs were normalized 0–1 across a whole ~29m
     quadrant, meaning one texture tile stretched over the entire quadrant with
     zero repeats. Fixed to use unnormalized global grid coordinates
     (`Vector2(col, row)`, not per-quadrant-local `Vector2(c, r)`) — one tile
     per `VERTEX_SPACING` interval (~1.83m), and using the *global* index
     also removes a seam that would otherwise appear at every quadrant
     boundary within a cell. Terrain3D: `Terrain3DTextureAsset.uv_scale`
     defaults to `0.1` (`uv = world_position * uv_scale`, one tile per 10m) —
     set to `1.0 / VERTEX_SPACING` in `Terrain3DTexturePool` to match the same
     real-world tile size as the old renderer's fix, keeping both visually
     consistent with each other.
   - **A real stutter regression, the same class 2.9–2.12 already fixed once
     for the old path — caused by this task's own culling fix above.** Real
     user report (a profiler capture): `Terrain3DBridge.import_cell()` costing
     75ms across 3 calls in one frame, a real "half a second of 30fps," not
     hypothetical. Root cause: `Terrain3DData::calc_height_range(true)`
     (`terrain_3d_data.cpp`, added for the culling-AABB fix above) recomputes
     **every** resident region's full height range from scratch on every
     single call, with no filtering to just the region(s) actually touched —
     confirmed by reading its source, a plain loop over all of
     `_region_locations`. Calling it unconditionally per cell import means
     cost grows with *total resident regions*, not O(1) per cell — cheap early
     in a session, increasingly expensive the longer play continues, matching
     exactly what was reported. Fixed by only recalculating the specific
     region(s) the just-imported cell touches
     (`Terrain3DRegion.calc_height_range()`, real per-region work, correctly
     unavoidable) then a cheap non-recursive
     `Terrain3DData.calc_height_range(false)` to re-aggregate the master range
     from each region's own already-correct cached value. Verified two ways:
     correctness unchanged (same `(0.0, 120.8)` real height-range result as
     before the fix) and a real 20-batch scaling test (9 new cells per batch,
     up to 174 total) showing per-batch cost stayed flat (10–40ms) instead of
     growing with resident-region count.
   - **A new, real, significant, NOT-yet-addressed finding surfaced while
     verifying the stutter fix's scaling behavior**: `Terrain3DData`'s region
     map is a **hard-coded, fixed 32×32 grid**
     (`REGION_MAP_SIZE = 32`, `terrain_3d_data.h`) — region locations are
     bounds-checked against `-16..15` on each axis and rejected outside that
     range (confirmed via real errors hit during the scaling test above, once
     it walked far enough from the origin). At `region_size = 64` (this
     design's chosen value), that caps real coverage at **32 × 64 = 2048
     vertex-intervals across, i.e. only a 64×64 real cell area** — the real
     scaling test above hit this bound at just ~48 cells from the origin in
     one direction. `WastelandNV` is real and known to be far larger than a
     64×64-cell area (see "Real-data findings" above — 16,388 `LAND` cells
     total, spanning a real coordinate range this test already exceeded with
     a small fraction of that). **This is a genuine architectural tension, not
     yet resolved**: the texture-budget finding specifically wanted a
     *smaller* `region_size` (64, not 256+) to keep per-region/per-neighborhood
     texture counts under the 32-slot budget, but `REGION_MAP_SIZE` being fixed
     means a smaller `region_size` also shrinks total representable world
     area — the two constraints pull in opposite directions. Real options,
     none vetted: (1) since `native/terrain3d` is a vendored submodule we
     already build from source (not a consumed prebuilt binary),
     `REGION_MAP_SIZE` could be patched upward directly — real, available,
     but unknown GPU/memory cost at a much larger value, and unknown whether
     other addon internals assume 32 elsewhere; (2) some kind of region-grid
     rebasing/windowing scheme (only ever representing a bounded area around
     the player, evicting/rebasing distant regions) — real work, ties directly
     into the still-not-built region-residency-removal policy below; (3)
     accept a bounded real play area for now and treat full-map coverage as a
     later problem. **Not investigated further this pass** — flagging clearly
     rather than picking an approach without discussion, since this affects
     the core region-size decision the rest of this design's texture-budget
     conclusions are built on.
   - **Still not done**: real LRU texture-slot eviction (see directly above —
     confirmed necessary now, not speculative); region create/keep-resident/
     eventual-removal policy *within* one active worldspace session as the
     camera moves (currently every imported cell's data stays resident for the
     worldspace's whole active session, matching "terrain is cheap to keep
     resident across a coarser radius" from "Streaming integration" above, but
     not yet the actual coarser-radius removal policy that section describes —
     also now more urgent, since it would naturally bound how many distinct
     textures are ever concurrently needed, easing the eviction problem too); a
     real, non-scratch `WorldStreamer`-level test exercising `use_terrain3d=true`
     through the normal `activate()`/`_check_streaming()` path (the scratch
     diagnostics above deliberately bypassed it); and further real play
     validation (the "good enough, real play verified" bar 2.12 used) before
     flipping the default.
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
