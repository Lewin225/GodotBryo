# 2.0 — Resource Caching + Instancing

Parent: [Phase 2](README.md)

## Goal

Stop rebuilding identical `ArrayMesh`/`ImageTexture`/`Material` resources for every
placement of the same base object. Fallout cells routinely place the same `STAT`
dozens or hundreds of times (rocks, fence posts, plants, generic clutter) — right now
each one triggers its own full BSA extract → NIF parse → submesh build → DDS decode →
texture upload, even when 50 REFRs point at the exact same `NIF`.

## Confirmed current state (not assumed)

`GamebryoMeshResolver` (`project/gamebryo/mesh_resolver.gd`) has no resource cache at
all:

- `load_nif()` (line 91) re-extracts and re-parses the NIF from its BSA every call.
- `build_submesh()` (line 114) builds a brand-new `ArrayMesh` every call.
- `load_texture()` (line 103) re-extracts and re-decodes the DDS and calls
  `ImageTexture.create_from_image()` every call.
- `populate_mesh_children()` (line 157) creates a fresh `StandardMaterial3D` per
  submesh, every call.

The only cache that exists is `_bsa_readers` (line 24) — open archive file handles,
not decoded mesh/texture data. Every one of Goodsprings' 108 placed objects in the 1.5
integration run rebuilt its geometry and textures from scratch, with zero sharing
between repeats.

## Steps

1. Add a mesh cache to `GamebryoMeshResolver`, keyed by resolved NIF path (and submesh
   index), returning the same `ArrayMesh` `Resource` for repeat placements instead of
   rebuilding. Same idea for `load_texture()`'s `ImageTexture` output, keyed by
   resolved texture path.
2. Once 2.1 (material pipeline) lands, extend the cache key to the full material
   (all texture slots + alpha mode), not just diffuse, so caching doesn't silently
   regress once multi-slot materials exist.
3. Quantify the win: re-run the Phase 1 integration scene
   (`project/test_phase1_integration.gd`) before/after, comparing wall-clock load time
   and the number of distinct `ArrayMesh`/`ImageTexture` resources actually allocated
   (a simple counter is enough — this project has no profiler infrastructure yet, and
   building one is out of scope here).
4. Investigate `MultiMeshInstance3D` batching for identical (mesh, material) pairs.
   Needs grouping REFRs by `base_form_id` at minimum (same base record ⇒ same mesh +
   material, guaranteed). Likely staged as a follow-up within this task rather than a
   prerequisite: caching alone captures most of the decode/upload cost; instancing is
   about draw-call count, a separate and later win. Needs its own design pass for how
   per-instance collision (still needed individually — `MultiMeshInstance3D` has no
   per-instance physics) coexists with a batched render representation.

## Deliverables

- Mesh/texture/material caching in `GamebryoMeshResolver`.
- A measured before/after comparison (load time, resource counts) on the Goodsprings
  cell, documented in this task's results.
- Either a working `MultiMeshInstance3D` prototype for at least one clearly-repeated
  prop type, or an explicit, reasoned deferral if per-instance collision restructuring
  turns out to be bigger than this task's scope.

## Acceptance criteria

- [x] Cache hit rate is measured and non-zero on a cell with repeated props
      (Goodsprings qualifies).
- [x] No correctness regression — `test_terrain.gd`, `test_object_registry.gd`,
      `test_interior_cell.gd`, and `test_phase1_integration.gd` all still pass.
- [x] Measured load-time / resource-count improvement is documented, not just assumed.
- [ ] `MultiMeshInstance3D` batching is either demonstrated or explicitly deferred with
      a stated reason.

## Results

Caching (mesh, texture, material, collision shape — all keyed by resolved path) was
added to `GamebryoMeshResolver` (`project/gamebryo/mesh_resolver.gd`), and
`populate_mesh_children()`/`populate_collision_children()` were changed to accept the
resolved `model_path` as a cache key (the two `object_registry.gd` call sites were
updated accordingly — the only two callers in the codebase).

Measured via a new benchmark, `project/test_resource_caching.gd`: loads the same two
cells (Goodsprings exterior + `GSDocMitchellHouse` interior, 536 placed objects total)
twice through one shared resolver — pass 1 cold, pass 2 entirely repeat placements of
objects pass 1 already resolved.

```
pass 1 (cold): placed=536 time=565.7ms  mesh_cache_hits=388  mesh_cache_misses=512
pass 2 (warm): placed=536 time=164.7ms  mesh_cache_hits=900  mesh_cache_misses=0
unique NIFs actually loaded: 266   unique textures actually loaded: 195
```

**3.4x faster on a full repeat load** (565.7ms → 164.7ms), with pass 2 landing at zero
mesh/material cache misses — every one of the 536 placements in pass 2 reused an
already-built resource, none rebuilt. Even **pass 1 alone** (first-ever load of these
two cells) had a 43.1% in-cell mesh cache hit rate (388/900): only 266 of the 536
placed objects' meshes are actually unique — the other ~270+ are repeats of a prop
already seen earlier in the *same* cold load. That's the concrete number behind "hundreds
of the same prop in a scene": more than half of any given cell's object placements were
already duplicate work before caching, not just across repeat loads.

## What's deferred

`MultiMeshInstance3D` batching was not attempted in this pass. Caching alone captures
the decode/build-cost win measured above; instancing is about draw-call count, a
separate concern, and grouping REFRs by `base_form_id` into `MultiMesh` buffers while
keeping per-instance collision correct is a real design task on its own — deferred
pending a decision on whether it's worth pursuing now or after seeing how far caching
alone gets Phase 2's actual streaming/frame-rate goals.

