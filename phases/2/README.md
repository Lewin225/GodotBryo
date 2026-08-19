# Phase 2 — World Streaming & Scale

Parent: [ROADMAP.md](../../ROADMAP.md)

Goal (per ROADMAP.md): move continuously through the game's actual worldspace, not one
cell at a time — adjacent-cell loading/unloading, interior/exterior transitions,
distant LOD, memory/streaming-radius tuning against the real Mojave worldspace.
Exit criterion: walk from Goodsprings to Primm without load screens beyond intended
interior transitions, at a stable frame rate.

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

## Open issues (parked, not yet investigated)

- **External lighting — window emissive backdrops.** Interior visuals are at/near
  parity with the base game as of 2.6, but exterior-facing lighting (light seen
  through windows from outside, and/or window-shaped emissive backdrop meshes used to
  fake exterior light/scenery) hasn't been looked at. Parked at the user's request to
  keep interior work unblocked — pick up next once resumed.

- **Per-cell lighting/tint data.** The interior sky/ambient fix (game.gd's
  `_set_exterior_environment()`) currently uses one flat, hand-picked ambient
  color/energy for every interior cell. Bethesda CELL records carry their own
  lighting subrecord (commonly `XCLL` for interior cells — ambient color, directional/
  "sun" color, fog color/near/far, directional rotation — and FNV additionally has
  `LGTM` "Lighting Template" records some cells reference instead of authoring their
  own) that the real game actually varies per cell. Not read or parsed anywhere yet —
  worth checking what's actually present in real cell data (byte-level, not assumed
  from documentation alone, per this project's own established discipline) before
  deciding whether to read it through and drive `_set_exterior_environment()`'s
  interior branch from real per-cell values instead of the current flat constant.

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
