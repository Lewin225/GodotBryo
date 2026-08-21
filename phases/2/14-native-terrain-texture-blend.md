# 2.14 — Native Multi-Layer Terrain Texture Blending

Parent: [Phase 2](README.md)

## Status

**Implemented and verified in real play (2026-08-21).** All 5 integration-plan steps
landed: `Terrain3DRegion`/`Terrain3DData` extended with the new per-vertex map types,
`main.glsl`'s `accumulate_material()` replaced with real sequential alpha-over,
`terrain3d_bridge.gd` rewritten to write real per-vertex IDs/weights, and
`terrain3d_texture_pool.gd`'s NaN-collision guard retired. Confirmed rendering with all
real layers blending correctly in real play.

**VCLR/VNML also landed (2026-08-21).** `EsmFile::get_land_data()` now parses both real
subrecords (raw bytes, undecoded — see `esm::LandData::vertex_normals_raw`'s own
comment for the real VNML decode formula) and exposes them to GDScript as
`vertex_colors`/`vertex_normals_raw`. `terrain3d_bridge.gd` writes real VCLR straight
into Terrain3D's existing `color_map` and real VNML (decoded) into the new
`TYPE_NORMAL` map, gated by `@export var import_authored_normals` with a
computed-from-heights fallback (same central-difference formula
`native/tools/vnml_check.cpp` verified this session, now the real-play fallback
instead of a one-off research check). `main.glsl` reads normals directly from
`_normal_maps` instead of recomputing them live every fragment, dropping the old
per-fragment height-diff normal calculation (and `WORLD_NOISE3`'s live brush-preview
perturbation, never enabled in this project — same deliberate scope cut as
`auto_shader`/`dual_scaling`).

The old control-map-painting tests (`test_terrain3d_multilayer_paint.gd`,
`test_terrain3d_texture_paint.gd`) were deleted as superseded — they exercised the
control-map `set_control_base_id`/`set_control_overlay_id` painting path this doc
replaced. No dedicated new test exists yet for the N=7 import path; real play is the
only verification so far.

Written after several rounds of real, live-play
bug-fixing on [2.13](13-terrain3d-integration.md)'s Terrain3D control-map integration
(bit-width widening 5→6→7 bits, a real IEEE-754 NaN control-value collision, per-vertex
overlay selection) converged on a structural conclusion, not just another bug: Terrain3D's
control map can only ever blend **2** textures at one point, and FNV's own real terrain
data routinely needs up to **7**. No amount of further bit-packing fixes that — it's the
format, not a bug in it. This doc is the result of a real design discussion (not a
unilateral decision) about what replaces it. Read [2.13](13-terrain3d-integration.md)
first — this doc supersedes only its **texturing** subsystem (control map + shading),
not its mesh/LOD/streaming/collision, which stay.

## Why not just keep patching Terrain3D's control map

Documented in full in [2.13](13-terrain3d-integration.md)'s "Real-data findings" —
summarized here because it's the direct motivation for this doc:

- Base/overlay texture-ID fields were widened twice (5→6→7 bits) chasing real
  texture-budget overflows, each requiring lockstep patches across the vendored addon's
  C++ *and* four GLSL shaders.
- The packed-`uint32`-reinterpreted-as-`float32` storage trick (Terrain3D's own design,
  not ours) has a real, confirmed IEEE-754 NaN collision: certain legal `(base, overlay)`
  ID combinations produce a bit pattern that `Terrain3DData::get_control()` treats as an
  "invalid" sentinel, corrupting real painted data into visible rainbow/magenta garbage.
  Closed twice (reserved slot 31, then slot 63) as the bit width grew — a real, recurring
  cost of the packed-float approach itself, not a one-off mistake.
- Even fully fixed, the format still only blends 2 textures at any point. Real FNV data
  needs more: the GECK wiki is explicit — *"each quad is limited to seven Land
  Textures"* — independently matching this project's own real census (worst real case:
  6 `ATXT` layers stacked on top of `BTXT`'s base at one point, 7 total).

## Why not just revert to the old per-cell renderer either

Also discussed at real length before settling on this design. `GamebryoTerrainBuilder`
(the pre-Terrain3D per-cell mesh builder) has no third-party format to fight, but has no
LOD at all — covering the same view distance at full detail means loading a
quadratically-growing number of full-resolution cell meshes, not a rounding error.
Building our own runtime LOD (vertex decimation, seam-stitching between LOD tiers) was
considered and set aside: it's real, substantial new engineering (crack-free LOD
transitions, tier-swap popping) to reproduce a cost curve Terrain3D's clipmap already
solves for free. Reusing Bethesda's own pre-baked distant-terrain data was also
considered — `ROADMAP.md`'s original phrasing assumed it might exist — but this
project's own prior LOD investigation already confirmed the opposite:
[`enginedocs/lod.md`](../../enginedocs/lod.md) states plainly that this engine ships **no
separate pre-baked terrain-LOD mesh format at all**, only hand-baked distant scenery
(`_lod.nif` companion meshes for buildings/landmarks like the Lucky 38 — [2.12](12-distant-object-lod.md)'s
own real data). There is no real pre-baked terrain LOD to reuse.

A decal-based middle ground (real Terrain3D clipmap texturing everywhere, with extra
projected-decal geometry layered on top only where real `ATXT` data has more than 2
layers) was also considered and rejected on principle, not cost: this project is an
engine *replacement*, not an approximation — decals would be rendering something not
directly, faithfully driven by real `LAND` data at the point it's rendered, which this
project's own working discipline doesn't allow.

**Chosen design**: keep Terrain3D for everything it's *not* the problem for — clipmap
mesh generation, LOD, shadows, region streaming, collision — and replace only its
control-map data model and the shader code that reads it, with a real, native N=7-layer
format driven 1:1 by `LAND`'s own real subrecords. This is a surgical replacement of one
subsystem inside an already-working pipeline, not a rewrite of the pipeline.

## Real ESM data model (the complete inventory, not assumed)

Scanned directly against every real `LAND` record in the base game and all nine
DLC/bonus-pack masters (42,474 records total, `native/tools/land_subrecord_dump.cpp` —
a one-off research tool, same convention as `terrain_census.cpp`):

| Subrecord | Real count | Size/vertex-grid | Currently used |
|---|---|---|---|
| `VHGT` | 41,989 | 1 `f32` offset + 33×33 `int8` deltas | Yes — height, unchanged by this doc |
| `BTXT` | 22,067 | 8 bytes: LTEX FormID(4) + quadrant(1) + pad(1) + unused(2) | Yes — base texture per quadrant |
| `ATXT` | 76,046 | 8 bytes: LTEX FormID(4) + quadrant(1) + pad(1) + `layer_index`(2) | Yes — overlay layer header |
| `VTXT` | 76,046 | sparse, 8 bytes/entry: position(2) + pad(2) + opacity `f32`(4) | Yes — per-vertex opacity for the preceding `ATXT` |
| `VCLR` | 29,681 | 33×33×3 bytes (RGB) | **Not yet** — real per-vertex color, this doc adds it |
| `VNML` | 41,989 | 33×33×3 bytes (XYZ) | **Not yet** — real per-vertex normal, this doc adds it |
| `DATA` | 42,473 | 4 bytes | No — see below |

`DATA` is genuinely unresolved: fopdoc itself documents it as "Unknown" with no byte
layout, and direct inspection of all 42,473 real values found only 10 distinct values,
all in a narrow low-bit range (`0x09`–`0x1F`, only bits 0–4 ever set) — the shape of an
editor/internal bookkeeping flag, not per-vertex geometry or texture data. Not decoded,
not planned; revisit only if a real, otherwise-unexplained visual issue ever traces back
to it.

One documentation discrepancy worth recording: fetching fopdoc's own `LAND` page
surfaced a listed `LTEX` subrecord ("array of LTEX record FormIDs") that **does not
appear anywhere** in the real, direct 42,474-record scan above. Trusting the real binary
data over the doc here, per this project's own established discipline — not chasing a
field that doesn't actually exist in real FNV `LAND` records.

### Real max layer count — confirmed two independent ways

1. This project's own census (`phases/2/13`'s "Real-data findings"): 169,892 quadrants
   scanned, 85.0% have zero `ATXT` layers beyond `BTXT`; the real worst case is 6
   additional layers stacked at one point (7 total including `BTXT`).
2. Bethesda's own GECK wiki, independently: *"each quad is limited to seven Land
   Textures."*

**N=7 is not a rounding-up guess — it's the real, confirmed, hard ceiling the original
engine itself enforces.** This design targets exactly 7, not more, per the user's own
framing: keep goals lofty (support the real max FNV/other Gamebryo-family titles can
express), but don't over-build past what's real.

**Important scope clarification, worth stating explicitly**: the 7-layer budget is
**per quadrant**, not per cell. Each cell has 4 independent quadrants, each with its own
real `BTXT` + up to 6 real `ATXT` layers — so one cell can reference up to **4×7=28**
distinct real textures in total, never more than **7 live at any single rendered
point**. This doesn't change the per-vertex storage design (a given vertex belongs to
exactly one quadrant, so 7 ID + 6 weight slots per vertex is always enough regardless of
how many total distinct textures the cell's other quadrants use), but it matters for not
under-provisioning anything scoped per-cell rather than per-vertex/per-quadrant — the
real whole-worldspace distinct-texture count (64, see below) already correctly accounts
for this since it counts real texture *paths*, not layer slots.

**A real, existing behavior this design inherits, not introduces**: `QUADRANT_RANGES`
(`terrain3d_bridge.gd`) are inclusive on both ends, so boundary vertices (row or col =
16) belong to *two* adjacent quadrants and get written twice — once per quadrant, in
iteration order — with whichever quadrant is processed later in the per-quadrant loop
winning. A boundary vertex therefore only ever gets *one* quadrant's real 7-layer set,
never a blend of both adjacent quadrants' data. This is already true of the current
control-map code and isn't something this redesign changes or needs to solve — just
worth stating so it isn't mistaken for a new gap once per-vertex storage makes each
vertex's single-quadrant scoping more visible.

### Real compositing model — sequential alpha-over, not winner-take-all

Every reduction attempt in [2.13](13-terrain3d-integration.md) (quadrant-wide single
overlay, then per-vertex single overlay) was an *approximation* forced by Terrain3D's
2-texture ceiling. With no such ceiling, there's no need to approximate: `ATXT`'s own
`layer_index` field is the real authored stacking order, and the real compositing model
is a straightforward painter's-algorithm alpha-over: start with `BTXT` as the opaque
base (implicit weight 1.0, no stored weight needed), then apply each `ATXT` layer in
increasing `layer_index` order, each one alpha-blending over the accumulated result by
its own real per-vertex `VTXT` opacity. This is not a heuristic — it's the literal
algorithm the original engine uses, and it handles all 7 real layers with one simple
loop, no "which layer wins" logic at all.

## Real per-vertex data design

### Texture IDs and blend weights (the core of this doc)

Deliberately **not** packed into a bit-shifted scalar reinterpreted as a float — that
exact technique is what caused the real NaN-collision bug this doc exists partly to
retire. Instead, natively-typed small-integer/normalized texture channels, each holding
exactly one real field, no bit math:

| Data | Real count needed | Format | Layout |
|---|---|---|---|
| Texture IDs (`BTXT` + up to 6 `ATXT`, sorted by real `layer_index` at import time) | 7 | `RGBA8`/`UNORM8`, decoded via `round(sample*255.0)` | 2 texture layers (8 channels, 1 spare) |
| Blend weights (`VTXT` opacity, `BTXT` has none — always full base) | 6 | `RGBA8`/`UNORM8` (quantized 0–255, same precision Terrain3D's own blend field already used) | 2 texture layers (8 channels, 2 spare) |

**Correction found during implementation**: `RGBA8UI` specifically doesn't exist as a Godot `Image::Format` — no 8-bit integer format exists at all (the smallest real integer formats are 16-bit signed, `FORMAT_R16I`/`RGBA16I` etc., present in the main project's `godot-cpp` but *not* in terrain3d's own older vendored `godot-cpp` submodule, which would need a separate version bump to use them). Since the real texture-ID/weight range is ≤256 distinct values, `FORMAT_RGBA8` normalized (decoded via `round(sample*255.0)`) is the right real format regardless — same technique Terrain3D's own existing blend field already used, no bit-packing, no float-reinterpret NaN class, no precision loss for values ≤255, and no unrelated submodule risk.

8-bit ID channels give **256** possible values per slot — confirmed comfortably
sufficient by direct measurement: the true, uncapped distinct-texture need for the
*entire* real `WastelandNV` worldspace (all 16,388 cells), measured by resolving every
real `BTXT`/`ATXT` reference unconditionally (not lazily, not winner-only — the real
number relevant to true N-layer blending), is **64**. ~4× real headroom over 256, and if
that ever proved wrong, the fix is a format swap (`RGBA8UI`→`RGBA16UI`) with zero
shader-side bit-math to redo — a structural advantage the packed-scalar format never
had.

Real per-region cost at `region_size=256` (65,536 vertices/region): (8+8) bytes/vertex
× 65,536 = **1 MiB** for the new ID+weight channels per resident region — small next to
the existing albedo texture array (~21MB for a full 126-slot pool).

### Vertex color (`VCLR`) — zero new cost

Terrain3D already has a real, built-in per-region `color_map` (`RGBA8`) layer, currently
left at its default (`COLOR_MAP_DEF`) because nothing populates it. Real `VCLR` data
slots directly into this **existing, already-supported** Terrain3D feature — no new
texture channel, no shader change beyond what Terrain3D's own material path already
does with `color_map`. A real, free win from data we weren't using.

### Normals (`VNML`) — decode solved this session, importer-toggleable

Real encoding, confirmed numerically (not assumed from docs — fopdoc documents this
field as unsigned `uint8` XYZ, which does *not* match; verified against 128,000 real
sample points across 2,000 real cells, comparing decoded `VNML` against a
central-difference normal recomputed from the same cell's own real `VHGT` heights):

```
component = int8_t(byte) / 127.0        // SIGNED byte, not unsigned
world.x =  component[0]
world.y =  component[2]                 // file stores (X, Z, Y) -- Bethesda's own
world.z = -component[1]                 //   internal axis order, not (X, Y, Z)
```

Raw decoded vector length averaged 0.995 (clean unit vectors, confirming the formula),
and the decoded normal matched the independently-recomputed one to **1.34° average, 53.5°
max** divergence across the full sample — mostly redundant with a computed normal, but
the real max divergence shows genuine extra fidelity at specific points (almost
certainly artist-smoothed cliff/edge geometry a naive central-difference recompute
wouldn't reproduce). Given the decode is now solved and cheap (4 bytes/vertex, 1 spare
channel in an `RGBA8` layer), this project's own bias toward real authored data over
computed approximation favors including it.

**Import toggle, not a hard requirement**: an `@export var import_authored_normals: bool
= true` on the terrain bridge — when `false`, skip `VNML` entirely and fall back to
normals computed from the heightmap (what every prior version of this pipeline has done
regardless). Cheap A/B lever, not a design commitment either way.

### Total new real per-vertex data

16 bytes (IDs + weights, the actual core ask) + 0 (`VCLR`, reuses existing Terrain3D
infrastructure) + 0 or 4 (`VNML`, toggleable) = **16–20 bytes/vertex** of genuinely new
data, all real, all ESM-driven, none fabricated.

## Integration plan — extend Terrain3D's region system, don't replace it

Since this is already a fork of the vendored addon (per 2.13's bit-width patches),
the natural fit is extending `Terrain3DRegion`'s existing real per-region `Image` slots
(today: height, control, color) with new ones for the ID/weight/authored-normal
channels, reusing Terrain3D's *entire* existing region lifecycle — `add_region_blank()`,
save/load, GPU texture-array generation (`update_maps()`) — rather than building a
parallel streaming system. Concretely (not yet implemented, this is the plan):

1. `terrain_3d_region.h`/`.cpp`: new `Ref<Image>` members for the ID-A/ID-B and
   weight-A/weight-B channels (and optionally authored-normal), with the same
   get/set/serialize pattern the existing `_control_map`/`_color_map` already use.
2. `terrain_3d_data.h`/`.cpp`: extend the region `MapType` enum and `update_maps()`'s
   dirty-tracking/GPU-array-rebuild logic to cover the new map types, following the same
   real incremental-vs-full-rebuild distinction [2.13](13-terrain3d-integration.md)
   already had to get right for height/control (the "only rebuild touched regions"
   fix, and the "new region forces a full rebuild" fix, both apply identically here).
3. `main.glsl`: **replace**, not extend, `accumulate_material()`'s 2-texture blend.
   New fragment logic samples the ID-A/ID-B and weight-A/weight-B texture arrays at the
   same 4-corner bilinear index Terrain3D already computes, then composites up to 7
   real texture-array samples via the real sequential alpha-over model above (`BTXT`
   implicit at the bottom, `ATXT` layers folded in stored-sorted-by-`layer_index`
   order). This is the one genuinely new, real shader-engineering piece — a fresh
   accumulation loop, not a patch to the existing one.
4. `terrain3d_bridge.gd`: `import_cell()`'s per-vertex write loop changes from
   `set_control()` (one packed value) to writing the new ID-A/B and weight-A/B images
   directly (`Image.set_pixel()`/`set_pixelv()` per vertex, same per-cell iteration
   shape already in place) — real layer_index-sorted ordering happens here, at import
   time, once per cell, not per-frame in the shader. Quadrant boundaries matter **only**
   here, and only as an input-grouping concept: knowing which quadrant a vertex belongs
   to (existing `QUADRANT_RANGES` logic, including the existing boundary-vertex
   last-quadrant-wins behavior) is how the importer knows which real `BTXT`/`ATXT` set
   and which local `VTXT` opacity index apply to that vertex. Once a vertex's up-to-7
   real layers are resolved and written, quadrant membership is fully discarded — the
   shader and the stored per-vertex data have no concept of quadrants at all, only real
   per-point layer data.
5. `terrain3d_texture_pool.gd`: `RESERVED_SLOT`/the NaN-collision guard **retire
   entirely** — nothing here reinterprets an integer as a float anymore, so the bug
   class this existed to work around can't occur. `USABLE_SLOTS` becomes a plain
   256-minus-pink budget, no reservation needed.

## Explicit non-goals for this task

- Any change to Terrain3D's mesh/LOD/streaming/collision machinery — none of that is
  the problem this doc solves, and none of it changes.
- Terrain3D's own `auto_shader`/`dual_scaling` editor conveniences — dropped from the
  new `accumulate_material()` entirely (not just left disabled). Neither is real,
  ESM-driven data (auto-shader procedurally *invents* texture placement from slope/
  height rules; dual-scaling is a second detail-UV pass for a single texture, unrelated
  to real layer count), and this project never enabled either (`_auto_shader`/
  `_dual_scaling` default `false`, confirmed nothing in `project/` sets them). Their
  `//INSERT:` uniform blocks at the top of `main.glsl` are untouched and still exist for
  compatibility, but the body-level insertion points inside `accumulate_material()` are
  gone — a real, deliberate scope cut, not an oversight.
- `debug_views.glsl`/`editor_functions.glsl`'s existing control-map-based texture ID
  visualization — still decodes `DECODE_BASE`/`DECODE_OVER` from the control map, which
  no longer drives real texturing after this doc. Now stale/inaccurate for debug
  purposes only (doesn't affect real rendering). Not fixed in this pass; a real
  follow-up if that debug view is still needed.
- Grass/scatter (`LTEX.GNAM`→`GRAS`, [2.13](13-terrain3d-integration.md)'s own
  "Real-data findings") — separate, already-scoped follow-on, untouched by this doc.
- Decoding `DATA` — genuinely unknown, not blocking, not planned unless real evidence
  surfaces later.
- Real LRU texture-slot eviction — same "not currently load-bearing, revisit if real
  play ever shows it's needed" status this had under the old design.

## Open implementation questions (not yet answered — next real work)

1. Real per-cell/per-region import cost for the new write pattern (4 extra `Image`
   writes per vertex instead of 1 packed `set_control()` call) — needs the same real
   profiling discipline [2.13](13-terrain3d-integration.md) applied to the original
   `import_cell()` cost (its `_diag_terrain3d_cost.gd`-style scratch tooling).
2. Real shader cost of a 7-sample (vs. 2-sample) accumulation loop at Terrain3D's
   existing 4-corner bilinear detail level (worst case up to 28 texture-array samples
   per fragment) — worth a real GPU profiling pass before assuming it's free, not
   assumed either way here.
3. Exact migration path off the current control-map-based rendering (parallel toggle
   during development, same coexistence-plan discipline 2.13 used for
   `GamebryoTerrainBuilder` vs. Terrain3D itself) — not designed yet.
4. Whether the 1-2 spare ID/weight channels get used for anything (a real 8th slot
   headroom, or future per-vertex flags) or stay reserved/unused.
