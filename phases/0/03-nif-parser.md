# 0.3 — NIF Mesh Parser Integration

Parent: [Phase 0](README.md)

## Goal

Take raw NIF bytes (from a BSA-extracted mesh file) and produce plain geometry:
vertex positions, normals, UVs, triangle indices, and material/texture references —
enough to render a static mesh. Skeleton/skinning/animation data is explicitly
deferred to Phase 3.

## Approach: integrate, don't reimplement

Do **not** start by writing a NIF parser from scratch. Evaluate existing clean-room
libraries first:

1. **`nifly`** (C++, actively maintained, clean-room, used by Skyrim/FO tooling) —
   first choice. Confirm it correctly reads the NIF version FNV uses (verify against
   a known-good FNV mesh, not just Skyrim ones, since `nifly`'s primary user base
   skews Skyrim/FO4).
2. If `nifly` has gaps for FNV's specific NIF version/node types, patch it rather
   than forking a whole new parser, and upstream fixes if feasible.
3. Only fall back to a from-scratch parser if integration proves impractical (license
   conflict, fundamental architecture mismatch) — document why before doing this,
   since it's a substantial time sink to avoid if possible.

## Steps

1. Vendor the chosen library into `native/nif/` (or as a proper dependency) and get
   it compiling as part of the 0.0 build.
2. Write a thin wrapper that: loads a NIF byte buffer, walks the node tree, and for
   each renderable node (`NiTriShape`/`NiTriStrips` or FNV-equivalent) extracts:
   - vertex positions, normals, UV coordinates
   - triangle index list
   - the material/texture reference (path into a BSA, typically via
     `NiTexturingProperty`/`BSShaderTextureSet` or equivalent for this NIF version)
   - the node's local transform (for meshes composed of multiple sub-shapes)
3. Confirm which NIF version(s) FNV actually ships (check a handful of real
   extracted meshes) so parsing assumptions are scoped correctly rather than
   supporting the entire historical NIF spec.
4. Export the extracted geometry to a portable intermediate format for inspection —
   glTF is the pragmatic choice (existing viewers, easy to eyeball correctness)
   before building the Godot-native resource path in 0.5.

## Deliverables

- `native/nif/` wrapper module: `LoadMesh(bytes) -> geometry + material refs`.
- A CLI/test that takes a NIF file path and writes a `.gltf` alongside it.

## Acceptance criteria

- [x] A simple static prop mesh parses without error and exports valid glTF geometry.
      Used `meshes/clutter/bobblehead/bobbleheadbart.nif` (4 submeshes, up to 987
      verts) and `meshes/furniture/school/schooldeskadirty01.nif` (2 submeshes, the
      smallest sample) as the small/simple cases. **Not visually cross-checked against
      NifSkope side-by-side** — no Windows-only NifSkope available in this Linux
      environment (same tooling gap as 0.1/0.2). Verified instead by: (a) decoding the
      exported glTF's base64 buffer back out in Python and confirming its byte length
      matches the declared `byteLength` and its first position matches accessor
      `min`/`max` bounds; (b) `jq`/`json.load`-level structural validation of all 9
      exported files (see Implementation notes).
- [x] Multi-sub-mesh NIFs export all sub-meshes with relative transforms: e.g.
      `meshes/vehicles/b29/b29_bombanim01.nif` has 62 submeshes (bomb bay doors, 12
      individual bombs, propeller blades, fireball VFX geometry), each exported as its
      own glTF node with its own local `matrix` (translation/rotation/scale flattened
      from nifly's `MatTransform`, see Implementation notes for the exact convention).
- [x] Texture path references extracted as raw strings, e.g.
      `textures\creatures\radroach\Radroach.dds`, `textures\vehicles\b29\B29bRun.dds`
      — correctly present on shapes that have a `BSShaderTextureSet`, empty on the few
      that don't (e.g. one collision-adjacent submesh in the UltraLux stairs sample).
      Not yet resolved through the BSA reader (0.1) — that's 0.5, as scoped.
- [x] 9 different static meshes from different game areas parsed cleanly in one test
      run: ammo, weapons, furniture, clutter/bobblehead, a creature (radroach),
      a vehicle (B-29), a casino interior dungeon piece, a tree, and an NCR
      architecture piece — plus the STAT-resolved guard tower mesh from 0.2, for 10
      total. NIF version confirmed as `20.2.0.7`, user version 11, stream version 34
      (`Gamebryo File Format, Version 20.2.0.7 / User Version: 11 / Stream Version:
      34`) across every sample — exactly nifly's `IsFO3()` range, confirming FNV uses
      the same NIF version as FO3 as expected.

### Follow-up / open item

Same as 0.1/0.2: no Windows-only reference tool (NifSkope) was available in this Linux
environment for a true visual side-by-side comparison. The buffer round-trip decode
and structural JSON validation (see above) are a strong substitute for "did we extract
the right numbers," but not for "does it look right" — if NifSkope or a compatible
Linux-friendly glTF/NIF viewer becomes available, opening a few of the exported
`.gltf` files (written to a scratch directory during testing, not committed — see
`project/test_nif.gd`) alongside their source `.nif` would close this out visually.

### Known limitation carried forward

No coordinate-system conversion is applied (Bethesda/NIF is Z-up, Godot is Y-up). The
raw `MatTransform` values (translation/rotation/scale) are passed through as-is to
both the `NifReader.get_transform()` Godot wrapper and the glTF exporter. This is
fine for 0.3's goal (prove geometry extraction works) but will need to be addressed
before 0.5's actual Godot scene integration or any real rendering — noted here so it
isn't rediscovered as a surprise later.

## Explicit non-goals for this task

- Skeletons, skinning weights, bone hierarchies (Phase 3).
- Animation/KF data (Phase 3).
- Collision data extraction (`bhk*` nodes) — needed in Phase 1 for collision shapes,
  but can be a fast-follow to this task rather than blocking it; note it as
  immediate next work once basic geometry extraction is solid.
- Havok physics properties beyond raw collision shape data (Phase 4).

## Implementation notes

- **Retroactive correction (found in [1.0](../1/00-interior-cell-loader.md)):**
  the triangle winding produced here was backwards (clockwise-front, matching
  NIF/Gamebryo's DirectX-lineage convention) rather than the counter-clockwise-
  front both Godot and glTF expect. Every mesh loaded through this module before
  the fix in `native/src/nif/nif_loader.cpp` (Phase 1) had reversed winding —
  not visually obvious from this task's outside-viewed standalone-prop
  screenshots, only caught once a full interior room was inspected up close
  from inside. Now fixed at the source, so no retroactive re-verification of
  0.3's own deliverables was needed beyond confirming the fix builds and
  renders correctly going forward.
- **Library choice**: used `nifly` (vendored as a git submodule at `native/nifly/`),
  per the task's own guidance to integrate rather than reimplement. It compiled
  cleanly against our existing toolchain with zero source changes needed — no forking
  or patching was required. Confirmed nifly explicitly supports FO3/NV via its
  `NiVersion::IsFO3()` check (`file == V20_2_0_7 && stream > 11 && stream < 83`) before
  committing to it, addressing the task's specific concern that nifly's primary user
  base skews Skyrim/FO4.
- Lives in `native/src/nif/` as part of the single `nv_engine` extension (same
  rationale as 0.1/0.2 — see [phases/0/README.md](README.md)). nifly's own sources
  (`native/nifly/src/*.cpp`) are globbed directly into the same SCons build rather than
  built as a separate static library — simplest option given nifly has no external
  dependencies beyond its own bundled headers (`external/half.hpp`, `Miniball.hpp`).
- `nif_types.h` — plain structs (`SubMesh`, `Mesh`) with flattened `float`/`uint32_t`
  arrays, deliberately not exposing any `nifly::` types in the public interface so
  downstream consumers (Godot wrapper, glTF exporter) don't need to link against nifly
  directly.
- `nif_loader.{h,cpp}` — pure C++, no Godot dependency. `load_mesh()` feeds the input
  byte buffer to `nifly::NifFile::Load(std::istream&)` via an `istringstream`, walks
  `NifFile::GetShapes()`, and for each shape with non-empty vertex data pulls
  positions/normals/UVs/triangles via nifly's `GetVertsForShape`/`GetNormalsForShape`/
  `GetUvsForShape`/`NiShape::GetTriangles`, the diffuse texture path via
  `GetTextureSlot(shape, tex, 0)` (resolves through `BSShaderTextureSet` for FO3/NV,
  per nifly's own documentation of that method), and the shape's local transform via
  `NiShape::GetTransformToParent()`. Shapes with no vertex data (collision proxies,
  etc.) are skipped — full `bhk*` collision extraction is explicitly out of scope here
  per the non-goals above.
- `gltf_export.{h,cpp}` — pure C++, no Godot/nifly dependency, generic glTF 2.0 writer
  (self-contained `.gltf` with the binary buffer embedded as a base64 data URI, no
  `.bin` sidecar). One glTF node + mesh per NIF submesh, with the submesh's local
  transform baked into the node's `matrix` (column-major, flattened directly from
  nifly's row-major `MatTransform` convention — see the "known limitation" above re:
  no Z-up→Y-up conversion). Texture paths are attached as `extras.texture_path` on
  each material rather than resolved to actual image data (that's 0.5's job once the
  BSA reader and a DDS decoder are wired together).
- `nif_reader_gd.{h,cpp}` — thin Godot-facing wrapper (`NifReader` : `RefCounted`)
  exposing `load()`, `get_nif_version()`, per-submesh accessors
  (`get_positions`/`get_normals`/`get_uvs`/`get_indices`/`get_texture_path`/
  `get_transform` returning a `Transform3D`), and `export_gltf()`. Follows the same
  pattern as `BsaReader`/`EsmReader`.
- **Bug caught during testing**: the first glTF export attempt produced invalid JSON
  (a stray double-comma between submeshes' accessor lists) because comma insertion was
  handled both by a per-submesh loop counter and independently by each attribute's own
  `accessor_index`/`view_index` counter, double-firing whenever a submesh had a
  variable number of optional attributes. Fixed by only using the running
  index-based counters (removing the redundant per-submesh comma), then verified by
  round-tripping all 9 exported files through Python's `json` module plus a manual
  base64-decode-and-byte-length check — this is the kind of error the "matches xEdit's
  histogram" style acceptance criteria elsewhere wouldn't have caught, so it's worth
  noting the verification method here explicitly.
- Test harness: `project/test_nif.gd` / `test_nif.tscn`, run via
  `tools/Godot_v4.7.1-stable_linux.x86_64 --headless --path project test_nif.tscn`.
  Exports `.gltf` files to a scratch directory (not committed) for inspection.
- One real-world wrinkle surfaced by this task: the STAT record resolved in 0.2
  (`architecture\NCR\NVGuardTower01a.NIF`) is **not** in the base
  `Fallout - Meshes.bsa` — it's shipped in `Update.bsa` instead (an NV-specific
  addition layered over the reused FO3 archives). Confirmed by grepping directory
  listings across all `Data/*.bsa` files. This previews real work for 0.5's
  integration tool: resolving a mesh path requires searching Data BSAs in load-order
  priority, not assuming a single archive.
