# Phase 0 — Groundwork

Parent: [ROADMAP.md](../../ROADMAP.md)

Goal: prove the toolchain and asset pipeline before any engine/gameplay work begins.
Nothing in this phase touches Godot's scene tree, physics, or gameplay — it is purely
"can we read Bethesda's files and get usable data out of them."

Phase 0 exit criterion (from the roadmap): **a standalone tool that unpacks a BSA,
finds a known mesh, and dumps it to glTF or a Godot-native mesh resource for manual
inspection.**

## Sub-tasks

Work roughly in this order — each one unblocks the next, except texture import
(0.4) which can run in parallel with the BSA/ESM/NIF work.

| # | Task | File |
|---|------|------|
| 0.0 | GDExtension build scaffolding | [00-build-scaffolding.md](00-build-scaffolding.md) |
| 0.1 | BSA archive reader | [01-bsa-reader.md](01-bsa-reader.md) |
| 0.2 | ESM/ESP record parser | [02-esm-parser.md](02-esm-parser.md) |
| 0.3 | NIF mesh parser integration | [03-nif-parser.md](03-nif-parser.md) |
| 0.4 | DDS texture import path | [04-dds-texture-import.md](04-dds-texture-import.md) |
| 0.5 | Integration: end-to-end dump tool | [05-integration-tool.md](05-integration-tool.md) |

Results write-up (after 0.5): [results.md](results.md)

## Dependency graph

```
0.0 (build scaffolding)
  └─▶ 0.1 (BSA reader) ─┐
  └─▶ 0.2 (ESM parser)  ├─▶ 0.5 (integration tool) ──▶ Phase 1
  └─▶ 0.3 (NIF parser) ─┤
  └─▶ 0.4 (DDS import) ─┘
```

0.1–0.4 are independent of each other and can be parallelized across contributors.
0.5 is the only task that requires all four to exist.

## Definition of done for Phase 0 as a whole

- [x] Native module builds and loads inside a Godot 4.x editor build on at least one
      platform (Linux or Windows — pick the primary dev platform first).
- [x] Given a path to a legally-owned FNV install, the tool lists the contents of
      `Fallout - Meshes.bsa`.
- [x] The tool extracts a specific known mesh (recommend `architecture/goodsprings/...`
      or a simple static prop — pick something small for fast iteration) and parses it
      with the NIF library without errors.
- [x] The parsed mesh's geometry (vertices, indices, UVs) is exported to glTF or a
      `.tres`/`.res` Godot mesh resource and opens correctly in the Godot editor or a
      glTF viewer, visually matching the original model.
- [x] A texture referenced by that mesh's material is located via BSA, decoded from
      DDS, and displays correctly on the mesh.
- [x] The ESM parser can open `FalloutNV.esm` and enumerate top-level record groups
      (`GRUP`) without crashing — full record decoding isn't required yet, just
      structural traversal (this becomes load-bearing in Phase 1).

**Phase 0 is complete.** See [results.md](results.md) for the full write-up: what
worked, two real integration bugs found and fixed by 0.5, and what needs to change
before Phase 1 planning starts (including `ResourceFormatLoader` and
`EditorFileSystem`/`EditorResourcePreview` integration, explicitly deferred past
Phase 0 — see results.md's "Deliberately deferred" section).

No performance targets, no error-recovery, no partial-data handling required at this
stage — the code can be thrown away or rewritten once Phase 1 defines real
requirements. The point of Phase 0 is derisking format assumptions, not shipping
production parsers.
