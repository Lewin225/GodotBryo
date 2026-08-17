# 2.6 — Vertex Color + Unlit Shading Fix

Parent: [Phase 2](README.md)

## Goal

Fix a real rendering bug: many props showed a bright white/solid border or blob where
the original game shows a soft shadow or ambient-occlusion fade — reported against
`CellRoot/NVCraftsmanFireplace/sub1`, `CellRoot/dlc04painting01/sub1`,
`CellRoot/SinkMetalRSTATIC01/sub1`.

## Finding: vertex colors were never extracted at all

Confirmed via a throwaway diagnostic against `NVCraftsmanFireplace.NIF` directly
through `nifly`: submesh `NVCraftsmanFireplace:6` has **no diffuse texture** and real
per-vertex colors ranging from `(1,1,1,0)` (fully transparent white) to `(0,0,0,1)`
(opaque black) — a classic texture-less, vertex-color-driven soft shadow/AO decal.
`nif_types.h`'s `SubMesh` had no field for vertex colors at all, and
`GamebryoMeshResolver._get_material()` returned Godot's default (opaque white)
whenever there was no diffuse texture — exactly matching the "white border" symptom.

**Fix**: added `colors` (flat RGBA) to `nif::SubMesh`, extracted via
`shape->HasVertexColors()` + `NifFile::GetColorsForShape()` in `nif_loader.cpp`.
Exposed via a new `NifReader.get_colors(index)`. Wired into
`GamebryoMeshResolver.build_submesh()` (as `Mesh.ARRAY_COLOR`) and `_get_material()`
(`mat.vertex_color_use_as_albedo = true`, folded into the material cache key since it
changes which pixels the material actually produces, not just how it looks).

## Finding: vertex-color decals also need to ignore scene lighting

After the above fix, the shadow blobs stopped being solid white — but still looked
washed out to a lit gray instead of a clean dark-to-transparent fade (reported directly
by testing: disabling the material's lighting fixed it, unsure if that was the
"correct" approach).

**Confirmed with real data, not just visual judgment**: dumped the actual NIF shader
block type per shape. The shadow blob (`NVCraftsmanFireplace:6`) uses
`BSShaderNoLightingProperty`; the normal textured submeshes on the same object use
`BSShaderPPLightingProperty`. This is Bethesda's own explicit signal, in the source
data, that a shape should render without being affected by scene lighting — not an
inferred heuristic ("no texture" alone isn't a safe signal; a shape could legitimately
have no diffuse texture for other reasons).

**Fix**: added `no_lighting` (bool) to `nif::SubMesh`, set via
`dynamic_cast<BSShaderNoLightingProperty*>(nif.GetShader(shape))`. Exposed via
`NifReader.is_unlit(index)`. Wired into `_get_material()`:
`mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED` when true (also part of the
cache key).

## Side finding, not fixed here

While isolating which submeshes had unusual (non-grayscale/saturated) vertex colors to
distinguish real decals from anything else, found `AudioMarker` (`Marker_Audio.NIF`)
and `XMarkerHeading` (`MarkerXHeading.nif`) — Construction-Kit-only editor helper
markers, texture-less, with strongly saturated vertex colors (blue/red) — being placed
and rendered as visible geometry (the "red/cyan blobs" visible in one screenshot during
this investigation). These are almost certainly meant to be invisible in actual
gameplay. Not addressed here — worth a follow-up (likely: recognize and skip these
specific marker base-record types in the registry, the same way `SOUN`/meshless `ACTI`
are already skipped).

## Verification

- Full existing test suite re-run (`test_object_registry.gd`,
  `test_phase1_integration.gd`, `test_resource_caching.gd`, `test_terrain_collision.gd`)
  — all pass, no regression.
- `GSDocMitchellHouse` re-screenshotted: the previously-visible white light-shaft
  streaks (unrelated ambient effect props using the same vertex-color mechanism) are
  now soft and correctly faded, not solid white.

## Deliverables

- Vertex color extraction (`nif_types.h`, `nif_loader.cpp`, `nif_reader_gd.{h,cpp}`).
- `BSShaderNoLightingProperty` detection, same files.
- `GamebryoMeshResolver` wiring (`build_submesh()`, `_get_material()`).
- This write-up.

## Acceptance criteria

- [x] The three reported objects (fireplace, painting, sink) no longer show a solid
      white border/blob.
- [x] The unlit fix is driven by real NIF shader-type data, not a texture-presence
      heuristic.
- [x] No regression in existing test suite.
- [ ] `AudioMarker`/`XMarkerHeading` (and similar CK-only markers) still render as
      visible geometry — flagged, not fixed, in this pass.
