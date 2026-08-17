# Phase 1 — Static World Rendering

Parent: [ROADMAP.md](../../ROADMAP.md)

Goal: walk a single exterior cell and a single interior cell with correct geometry,
textures, and collision. No NPCs, no AI, no scripting, no combat — those are later
phases. Builds directly on Phase 0's proven ESM/BSA/NIF/DDS pipeline; nothing here
reinvents that, it's about placing many objects correctly rather than one.

Design docs (read before implementing 1.1+): [object-types.md](object-types.md) (the
full checklist of placeable record types) and [architecture.md](architecture.md) (the
layered node design and factory-registry pattern these tasks build).

## Sequencing rationale

Interior cells come first, deliberately. An interior `CELL` has no `WRLD`/`LAND` —
it's just a list of `REFR`s, resolved through the exact pipeline
[0.5](../0/05-integration-tool.md) already proved end-to-end. Exterior cells bundle
three genuinely new subsystems at once (worldspace parsing, heightmap terrain
generation, texture splatting) with zero Phase-0 precedent. Sequencing interior first
means the riskiest, least-proven work (terrain) doesn't block validating everything
else — the same reasoning that kept 0.1–0.4 independent of each other.

Within interior-cell work: static geometry (`STAT`) before the broader object-type
registry, before collision, before lights — each step is a strict superset of the
last, and each is independently useful/demoable rather than one big all-or-nothing
cell loader.

## Sub-tasks

| # | Task | File |
|---|------|------|
| 1.0 | Interior cell loader (STAT-only) | [00-interior-cell-loader.md](00-interior-cell-loader.md) |
| 1.1 | Object-type registry (FURN/CONT/ACTI/DOOR/...) | [01-object-type-registry.md](01-object-type-registry.md) |
| 1.2 | Collision extraction (NIF `bhk*` → Godot shapes) | [02-collision-extraction.md](02-collision-extraction.md) |
| 1.3 | Light sources (`LIGH` → real Godot lights) | [03-light-sources.md](03-light-sources.md) |
| 1.4 | Exterior cell + terrain (`WRLD`/`LAND`) | [04-exterior-cell-terrain.md](04-exterior-cell-terrain.md) |
| 1.5 | Integration: both default cells, full exit criterion | [05-integration.md](05-integration.md) |

## Dependency graph

```
1.0 (interior STAT-only)
  ├─▶ 1.1 (object-type registry) ──▶ 1.3 (lights, registers into 1.1's registry)
  ├─▶ 1.2 (collision extraction — independent of object-type breadth, can run
  │         in parallel with 1.1 once 1.0 gives it a cell to test against)
  └─▶ 1.4 (exterior/terrain — LAND/terrain generation is independent of 1.1, but
            full exterior REFR population reuses 1.1's registry once it exists)

1.1, 1.2, 1.3, 1.4 all ─▶ 1.5 (integration — needs everything)
```

1.2 and 1.4's terrain-generation half can be parallelized against 1.1/1.3, similar to
how 0.1–0.4 were independent in Phase 0. 1.5 is the only task that needs everything,
same shape as 0.5.

## Definition of done for Phase 1 as a whole

- [x] A default interior cell (`GSDocMitchellHouse`, FormID `00103DF9`) loads with
      correct static geometry, correct textures, and walkable collision.
- [x] Interior cells are loadable generically by EditorID or FormID, not just the
      hardcoded default — demonstrated against at least one other interior cell
      beyond Doc Mitchell's house.
- [x] `FURN`/`CONT`/`ACTI`/`DOOR` and the rest of the confirmed-shape object types
      (see [object-types.md](object-types.md)) render alongside `STAT` in the same
      cell, each as its own typed node per [architecture.md](architecture.md).
- [x] `LIGH` records produce real, correctly-placed Godot light sources — benchmark
      is correct placement, not falloff-curve fidelity to the original.
- [x] A default exterior cell (Goodsprings) loads with heightmap terrain, splatted
      ground textures, and placed static objects.
- [x] Collision is walkable in both the interior and exterior default cells — derived
      from NIF `bhk` data where present, falling back to a bounding-box/convex-hull
      approximation where not yet extracted.
- [x] Unsupported/unregistered reference types (actors, leveled lists, anything not
      yet cataloged) are skipped with a log line, not a crash — per
      [architecture.md](architecture.md)'s registry fallback design.
- [x] A basic free-fly/no-clip camera controller exists — not the real player
      controller (later phase), just enough to inspect loaded cells interactively.

**All Phase 1 exit criteria are met — see [phases/1/results.md](results.md).**

No performance targets and no streaming — Phase 1 loads exactly the cells it's asked
to load, once, and stops there. Continuous multi-cell streaming is Phase 2.
