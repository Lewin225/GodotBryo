# 0.4 — DDS Texture Import Path

Parent: [Phase 0](README.md)

## Goal

Get a BSA-extracted `.dds` texture displaying correctly on a mesh in Godot. This is
the smallest task in Phase 0 — Godot already has DDS support — so the work is mostly
verification, not new parsing code.

## Steps

1. Extract a handful of representative textures from `Fallout - Textures.bsa` via the
   0.1 BSA reader (a diffuse map, a normal map, and anything using an unusual
   compression variant if easily identified).
2. Confirm Godot's built-in DDS importer accepts them directly. FNV-era textures are
   typically BC1/DXT1 (opaque diffuse), BC3/DXT5 (diffuse+alpha, normal maps), and
   possibly BC7 for some later-DLC assets — check what Godot's importer supports out
   of the box and note any gaps.
3. If any variant fails to import, determine whether it's a Godot importer
   limitation (file an issue / check existing Godot issues) or a nonstandard header
   Bethesda's tooling emitted (some older Bethesda DDS files are known to have
   slightly nonconforming headers) — fix at the header-normalization level if so,
   rather than writing a full DDS decoder.
4. Confirm color space handling is correct (diffuse textures typically sRGB, normal
   maps linear) — this is an easy silent-correctness bug (textures "work" but look
   washed out or too dark) rather than a hard failure, so check visually against a
   reference screenshot or the NifSkope preview, not just "did it import."

## Deliverables

- A short note (`native/dds-notes.md` or inline in this file's follow-up) documenting
  which DDS variants FNV uses and which of those Godot handles natively vs. need
  preprocessing.
- If preprocessing is needed: a small conversion step in `native/dds/` (or reuse of
  an existing library) that normalizes headers before handoff to Godot.

## Acceptance criteria

- [x] A diffuse texture and a normal map, both extracted from the real BSA, display
      correctly (correct colors, no channel swaps, no upside-down/mirrored UVs) when
      applied to the Phase 0.3 test mesh in the Godot editor. Used
      `textures/architecture/ncr/ncr_guardtower01.dds` (diffuse, BC1/DXT1) and its
      `_n.dds` counterpart (normal map, BC3/DXT5) on `meshes/architecture/ncr/
      nvguardtower01a.nif` — the same STAT-resolved mesh carried through from 0.2 and
      0.3, so this closes the loop on one real, traceable game object end-to-end:
      ESM record → NIF geometry → BSA-extracted textures → rendered in Godot. Rendered
      with a real GPU (Vulkan/Forward+, not headless/software) and visually confirmed:
      correct wood/metal/diamond-plate material colors, riveted-metal bump detail
      visibly coming from the normal map, no mirrored or flipped UVs.
- [x] Texture format gaps documented (none found) — see below.

### DDS format survey

Sampled ~1,370 `.dds` files' headers across `Fallout - Textures.bsa`,
`Fallout - Textures2.bsa`, and two DLC archives (`HonestHearts - Main.bsa`,
`LonesomeRoad - Main.bsa`) by reading each file's FourCC (and, for the handful with no
FourCC, the uncompressed-format flags) via the 0.1 BSA reader:

| Variant | FourCC / flag | Godot `Image.Format` | Notes |
|---|---|---|---|
| BC1 (opaque/1-bit-alpha diffuse) | `DXT1` | `FORMAT_DXT1` (17) | ~68% of samples — the overwhelming majority |
| BC2 | `DXT3` | `FORMAT_DXT3` (18) | ~4% of samples |
| BC3 (diffuse+alpha, normal maps) | `DXT5` | `FORMAT_DXT5` (19) | ~25% of samples |
| Uncompressed RGB/RGBA | `DDPF_RGB` / `DDPF_RGB\|DDPF_ALPHAPIXELS` (no FourCC) | `FORMAT_RGB8` (4) / `FORMAT_RGBA8` (5) | rare (e.g. `textures/water/waterwaves.dds`, some mouth/teeth textures) |

**No BC7 or DX10-header (`DX10` FourCC) textures found anywhere in the sample**,
including DLC content — consistent with FNV being a 2010, DirectX 9-era engine (BC7 is
a DX11+/DXGI feature). This means Godot's importer coverage is complete for this game;
no format gaps to design around.

**One real gap found, and it's not a format issue**: `Image.load()` (the generic
runtime loader) returns `ERR_FILE_UNRECOGNIZED` (15) for every `.dds` file tested,
even though the editor's *import* pipeline handles `.dds` natively (`*.dds` is in its
recognized-extensions list). The fix is trivial — use the dedicated
`Image.load_dds_from_buffer()` entry point instead of the generic `load()`/
`load_from_file()` path — but it's worth documenting since it wasn't obvious from the
phase doc's original "Godot already has DDS support" framing, and would have looked
like a hard failure if not for this note.

## Explicit non-goals for this task

- Texture compression/recompression tooling.
- Mipmap regeneration beyond whatever Godot's importer already does.
- Material graph setup (PBR parameter mapping from Gamebryo shader properties) —
  a plain unlit/simple-lit material is sufficient to visually confirm the texture
  data is correct; proper material/shader translation is later-phase work once
  rendering quality actually matters.

## Implementation notes

- No new files under `native/dds/` were needed — per the format survey above, every
  DDS variant FNV actually uses is already handled by Godot's built-in DDS decoder via
  `Image.load_dds_from_buffer()`. This task ended up being verification-only, exactly
  as the phase doc predicted ("the smallest task in Phase 0").
- Color space: used a plain `StandardMaterial3D` with `albedo_texture` set directly
  from the decoded diffuse `Image` and `normal_texture` (with `normal_enabled = true`)
  from the decoded normal map — Godot's `StandardMaterial3D` already treats
  `albedo_texture` as sRGB and `normal_texture` as linear by default, so no explicit
  color space handling was required. Visually confirmed correct: the diffuse render
  isn't washed out or too dark, and the normal map is visibly contributing
  bump/rivet detail rather than being misinterpreted as color data.
- Test/demo harness: `project/test_dds.gd` / `test_dds.tscn`. Unlike 0.1–0.3's test
  harnesses, this one can't run under `--headless` — actually rendering a frame to
  inspect (not just parsing bytes) needs a real rendering context, and `--headless`
  hung indefinitely waiting on `await get_tree().process_frame` (headless mode doesn't
  drive the render loop the same way). Ran instead with the host's existing X display
  (`DISPLAY=:0 tools/Godot_v4.7.1-stable_linux.x86_64 --path project test_dds.tscn
  --resolution 1200x900`), which picked up the host's NVIDIA GPU via Vulkan/Forward+
  automatically. This is a one-off manual/visual-inspection run, not part of the
  headless CI-style pattern established by 0.1–0.3 — documented here so it isn't
  mistaken for a regression later when `--headless` "stops working" for this specific
  test.
- The demo harness builds the actual 0.3 NIF mesh (all 3 submeshes, real local
  transforms via `NifReader.get_transform()`) with real BSA-extracted textures
  applied, adds a camera framed from the mesh's world-space AABB and a directional
  light, and saves a screenshot (`.png`, written to a scratch directory, not
  committed) — this is the artifact that was visually reviewed to confirm the
  acceptance criteria above.
- Applied the Z-up (NIF) → Y-up (Godot) conversion flagged as a known limitation in
  0.3's doc: rather than transforming every vertex, the demo's scene root is rotated
  -90° about X, which maps `(x, y, z) → (x, z, -y)` — the standard axis remap — for
  the whole hierarchy at once. This is the first task where that conversion actually
  mattered (0.3's glTF export didn't apply it, and glTF viewers didn't care since nifly
  meshes stayed self-consistent either way); 0.5's integration tool will need to make
  this conversion a first-class, permanent part of the NIF-to-Godot pipeline rather
  than a one-off in a test script.
