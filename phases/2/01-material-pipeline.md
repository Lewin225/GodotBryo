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

- [ ] Texture slot assignments are confirmed against real NV NIF data, not assumed
      from another game's convention.
- [ ] Alpha-tested/blended objects render with correct transparency (not opaque, not
      invisible).
- [ ] Normal maps visibly affect shading on at least one confirmed test object.
- [ ] No regression in existing 1.4/1.5 screenshot tests.
