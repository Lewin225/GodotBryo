# Phase 2 — World Streaming & Scale

Parent: [ROADMAP.md](../../ROADMAP.md)

Goal (per ROADMAP.md): move continuously through the game's actual worldspace, not one
cell at a time — adjacent-cell loading/unloading, interior/exterior transitions,
distant LOD, memory/streaming-radius tuning against the real Mojave worldspace.
Exit criterion: walk from Goodsprings to Primm without load screens beyond intended
interior transitions, at a stable frame rate.

**Exit criterion validated in real play** (2026-08-20, after 2.9/2.10/2.11 landed):
Goodsprings → Primm, Goodsprings → Lucky 38, and Goodsprings → Hoover Dam all walked
successfully, no load screens beyond intended interior transitions, vsync-capped frame
rate throughout — most of the exterior map explored. Distant LOD (2.12) has since
landed and been verified in real play too, including two real streaming-stutter fixes
(synchronous per-tile construct, and un-throttled new-tile-load starts causing a whole
ring "edge" to pay its terrain-build cost in one frame) caught via user-provided in-play
perf reports during that same verification pass — flying across the map now costs a
frame-rate dip, not a stutter. Streaming-radius/memory tuning against the real Mojave
worldspace is still open (the current radii are real, working values from this same
session, not yet a dedicated tuning pass).

**This README originally only scoped the performance-track tasks below** — surfaced
during a post-1.5 experiment (`project/exterior_viewer.gd`, a `@tool` editor scene that
loads an *area* of exterior cells rather than one hardcoded default) and a follow-up
discussion about what "loading things proper" at Fallout's actual prop density
requires. Interior/exterior door transitions (2.7) and continuous cell grid streaming
(2.8) now have their own task files too. Distant LOD and streaming-radius/memory
tuning still need their own planning
pass, informed by whatever these performance tasks find, before those get their own
task files.

## Sub-tasks

| # | Task | File |
|---|------|------|
| 2.0 | Resource caching + instancing (mesh/material dedup) | [00-resource-caching-instancing.md](00-resource-caching-instancing.md) |
| 2.1 | Material pipeline completeness (normal/alpha/specular) | [01-material-pipeline.md](01-material-pipeline.md) |
| 2.2 | Async/streamed cell loading (production version of the exterior_viewer.gd prototype) | [02-async-streaming-loader.md](02-async-streaming-loader.md) |
| 2.3 | REFR rotation composition order fix | [03-refr-rotation-order.md](03-refr-rotation-order.md) |
| 2.4 | Articulated prop transform flattening fix | [04-articulated-prop-transforms.md](04-articulated-prop-transforms.md) |
| 2.6 | Vertex color + unlit shading fix | [06-vertex-color-transparency.md](06-vertex-color-transparency.md) |
| 2.7 | Runtime cell loader (door-triggered, interior/exterior unified) | [07-runtime-cell-loader.md](07-runtime-cell-loader.md) |
| 2.8 | World cell streaming (adjacent-cell load/unload, active-camera-driven) | [08-world-cell-streaming.md](08-world-cell-streaming.md) |
| 2.9 | Direct RenderingServer/PhysicsServer3D geometry (kill per-node overhead for non-interactive placements) | [09-direct-server-static-geometry.md](09-direct-server-static-geometry.md) |
| 2.10 | Threaded tile resolve (WorkerThreadPool) — 2.2's threading investigation, informed by a real measured frame-time budget | [10-threaded-streaming-workers.md](10-threaded-streaming-workers.md) |
| 2.11 | Exterior cell lookup index — fix `find_exterior_cell()`'s real O(worldspace) scan cost using the ESM's own block/sub-block structure (found to be 81% of tile-streaming settle time) | [11-exterior-cell-lookup-index.md](11-exterior-cell-lookup-index.md) |
| 2.12 | Distant object LOD — Bethesda's own `_lod.nif` paired-mesh convention, gated by the real "Visible When Distant" REFR flag, via Godot's `visibility_range_begin/end` | [12-distant-object-lod.md](12-distant-object-lod.md) |
| 2.13 | Terrain3D integration — implementation in progress, real bugs found/fixed live; region-based clipmap terrain replacing per-cell `GamebryoTerrainBuilder`. Its control-map texturing (2-layer max) is being superseded by 2.14 | [13-terrain3d-integration.md](13-terrain3d-integration.md) |
| 2.14 | Native multi-layer terrain texture blending — implemented and verified in real play, replacing Terrain3D's 2-texture control map with a real 7-layer format matching FNV's own `BTXT`/`ATXT`/`VTXT` data, keeping Terrain3D's mesh/LOD/streaming/collision. VCLR/VNML also landed | [14-native-terrain-texture-blend.md](14-native-terrain-texture-blend.md) |

## Open issues (parked, not yet investigated)

- ~~**External lighting — window emissive backdrops.**~~ **Resolved** by
  [PR #31](https://github.com/Lewin225/GodotBryo/pull/31) (closing
  [issue #26](https://github.com/Lewin225/GodotBryo/issues/26)):
  `EsmFile`/`EsmReader` now resolve `REFR.XEMI` ("External Emittance") links to
  their authored `LIGH`/`REGN` tint color, and additive `NoLighting` effect
  materials (light beams, window-glow backdrop meshes) render through a
  dedicated shader that applies that tint while ignoring dynamic `LIGH`
  overlap — the general mechanism Bethesda uses for window-shaped emissive
  backdrops. Real-data coverage against `GSGeneralStore` and Doc Mitchell's
  House confirmed both the cookie tint and beam behavior. Genuine light
  bleeding through window glass geometry (a distinct rendering concern from
  the authored XEMI tint mechanism) was not in scope for this PR and remains
  unverified.

- ~~**Per-cell lighting/tint data.**~~ **Done.** `EsmFile::get_cell_lighting_data()`
  parses the real `CELL.XCLL` subrecord (ambient/directional/fog color, fog near/far,
  directional rotation/fade, fog clip/power — confirmed byte-level against real cell
  data, not assumed from documentation), and `game.gd`'s `_apply_cell_lighting()` now
  overrides the shared `interior_environment.tres` baseline's ambient color per cell on
  load. `LGTM` "Lighting Template" records (some cells reference one instead of
  authoring their own `XCLL`) are still unhandled — a real, narrower follow-up if a
  cell with no `XCLL` but a real `LGTM` reference turns out to matter in practice.

## Why these three, and why now

Phase 1 proved *correctness* (one interior cell, one exterior cell, loaded once, no
performance targets — explicitly out of scope per `phases/1/README.md`). Phase 2's
whole premise is scale: many cells, continuously, at a stable frame rate. Loading each
cell the way Phase 1 does — a fresh `ArrayMesh`/`ImageTexture` per REFR, single
diffuse-only materials, everything built synchronously in one frame — works for one
cell loaded once, but Fallout cells routinely place the same prop (rocks, fence posts,
plants, clutter) dozens of times, and Phase 2 needs many cells resident at once. These
three tasks are the load-bearing prerequisites for Phase 2's own exit criterion, not
speculative optimization:

- **2.0/2.1** determine how much real work each cell load actually costs (duplicate
  decode/upload work, missing material fidelity) — needed before streaming-radius/
  memory-budget tuning (ROADMAP's own Phase 2 bullet) means anything.
- **2.2** determines whether cell loads can happen without a frame hitch at all —
  directly the "without load screens... at a stable frame rate" exit criterion.
