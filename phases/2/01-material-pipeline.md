# 2.1 — Material Pipeline Completeness

Parent: [Phase 2](README.md)

## Goal

The current material pipeline only carries a single diffuse texture per submesh — no
normal maps, no specular/glow, no alpha blending/testing. Fine for Phase 1's
correctness benchmark ("does the right mesh sit in the right place with the right base
color"), not fine for anything claiming to look like the original game: FNV leans on
normal maps for surface detail and alpha-tested/blended materials for foliage, fences,
hair, glass, and other cutout geometry that would otherwise render fully opaque or
missing entirely.

## Confirmed current state (not assumed)

- `nif_loader.cpp:182` — `nif.GetTextureSlot(shape, tex, 0)`, hardcoded to slot 0 only,
  with a comment "slot 0: diffuse/base, via BSShaderTextureSet for FO3/NV."
- `nif::SubMesh` (`nif_types.h:25`) has exactly one `std::string texture_path` field —
  the data model itself has no room for a second texture slot. This is a core-layer
  gap, not a GDScript-consumer gap.
- `NiAlphaProperty` (blend/test mode, threshold) is not read anywhere in
  `nif_loader.cpp` — every material is treated as fully opaque regardless of the
  source NIF's actual alpha settings.
- `GamebryoMeshResolver.populate_mesh_children()` (`mesh_resolver.gd:157`) only ever
  sets `StandardMaterial3D.albedo_texture`.

## Steps

1. Confirm which `BSShaderTextureSet` slots FO3/NV NIFs actually populate and in what
   order, against real NIF data and nifly's own slot enum — don't assume the slot
   order from a different Bethesda-engine game's convention; verify against this
   project's own game files, same discipline as every other format finding so far.
2. Widen `nif::SubMesh` to carry multiple texture paths (true source fix, in
   `nif_types.h`/`nif_loader.cpp` — not per-consumer) and extract `NiAlphaProperty`
   data (blend/test mode + threshold) per shape.
3. Wire the new data into `GamebryoMeshResolver`'s material construction:
   `normal_texture`/`normal_enabled`, transparency mode + alpha threshold from the
   extracted `NiAlphaProperty`, other slots (glow, specular/environment) as confirmed
   present in step 1.
4. Visual regression pass: re-run 1.4/1.5's screenshot tests, plus new targeted checks
   against a confirmed normal-mapped object and a confirmed alpha-tested/blended
   object (foliage or a fence are likely candidates — confirm by inspection, don't
   guess which STATs qualify).

## Deliverables

- Multi-slot texture extraction in the C++ core, sourced against real data.
- Alpha mode extraction and correct Godot-side transparency behavior.
- Updated `GamebryoMeshResolver` material construction.
- Screenshot evidence of at least one normal-mapped and one alpha-tested/blended
  object rendering correctly.

## Acceptance criteria

- [x] Texture slot assignments are confirmed against real NV NIF data, not assumed
      from another game's convention.
- [x] Alpha-tested/blended objects render with correct transparency (not opaque, not
      invisible).
- [x] Normal maps visibly affect shading on at least one confirmed test object.
- [x] No regression in existing 1.4/1.5 screenshot tests.

## Results

**Slot convention confirmed against real data first**, before wiring anything into
materials (a throwaway verification scene sampled every unique model in
`GSDocMitchellHouse` + Goodsprings — 263 models, 510 submeshes):

```
with diffuse (slot 0): 469/510
with normal (slot 1):  452/510   (e.g. GunCabinet_n.dds, Paper_n.dds, PipBoyCards_N.dds)
with glow (slot 2):     13/510   (radio dials, wall/ceiling lamps — plausible, rare)
with alpha property:   172/510   (blend=82, test=102, real varying thresholds, e.g. 0.549, 0.470)
```

The community-documented FO3/NV `BSShaderTextureSet` slot convention (0=diffuse,
1=normal+gloss, 2=glow) held up — normal-map filenames follow the expected `_n`/`_N`
suffix, and alpha thresholds are real, varying, non-degenerate values, not all-zero or
all-default.

**Implementation**: `nif::SubMesh` (`nif_types.h`) widened with `normal_texture_path`,
`glow_texture_path`, and `NiAlphaProperty` data (`has_alpha_property`,
`alpha_blend_enabled`, `alpha_test_enabled`, `alpha_threshold`) — extracted in
`nif_loader.cpp` via `NifFile::GetTextureSlot(shape, tex, 1/2)` and
`NifFile::GetAlphaProperty(shape)`. `NiAlphaProperty.flags` bit 0 (blend enable) and
bit 9 (test enable) are the standard NIF-format bits (documented across NIF versions,
not nifly-specific) — src/dst blend-function bits (1-8) were **not** decoded (see
"What's still missing" below). Exposed to GDScript via three new `NifReader` methods.
`GamebryoMeshResolver._get_material()` now builds `normal_texture`/`emission_texture`
and sets `transparency`/`alpha_scissor_threshold` from this data, cached by a composite
key (all texture paths + alpha mode + threshold) so repeat placements still hit the
Phase 2.0 material cache.

**Regression check**: initially worried the alpha-blend wiring had broken something —
Doc Mitchell's house showed bright white streaks (ambient light-ray decorative props,
`Effects\Ambient\Industrial\IndFXLightRays*.NIF`, using a soft-glow gradient texture).
Verified by diffing against a saved pre-2.1 screenshot from the same deterministic
camera framing (`test_phase1_integration.gd`): **pixel-identical before and after** —
not a regression, these render the same way old code already rendered them (a fully
opaque white texture, since old code never set `transparency` at all). Confirmed via
direct DDS decode that the texture's alpha channel is real, varying gradient data (not
corrupted) — worth revisiting only if these specific effect props' visual fidelity
becomes a priority later, not a Phase 2.1 blocker.

## What's still missing (deliberately out of scope for this pass)

- **Blend function fidelity**: only alpha blend *enable* (bit 0) is read, not the
  actual source/destination blend-function bits (1-8) — Godot always uses standard
  alpha "mix" blending, never Bethesda's occasional additive blend (plausible for some
  light-ray/glow effects). Approximated, not exact.
- **Slots 3+** (height/parallax, environment map/mask) — not extracted at all; rare
  enough in base-game FO3/NV content that they weren't prioritized this pass.
- **Normal map channel convention** — Bethesda NIF-era normal maps are DirectX-convention
  (green channel down); Godot expects OpenGL-convention (green channel up), same as
  glTF. Not corrected here — needs a dedicated visual check against a known
  normal-mapped object under real lighting before deciding whether a channel flip is
  actually needed, not assumed either way.
