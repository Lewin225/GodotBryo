# 2.4 — Articulated Prop Transform Flattening Fix

Parent: [Phase 2](README.md)

## Goal

Fix a real placement bug distinct from [2.3](03-refr-rotation-order.md)'s REFR
rotation fix: objects with a "moving part" (doors, lidded containers, fridges) render
with that part — and sometimes the whole object — positioned wrong, independent of the
REFR's own rotation. Reported as: a fridge embedded halfway in the floor, and doors/lids
not aligned with their static "sister" mesh.

## Finding

`nif_loader.cpp` computed each render `NiShape`'s transform via
`shape->GetTransformToParent()` — which, confirmed against `nifly`'s source
(`Objects.hpp:60`), returns the transform relative to that shape's **immediate**
parent block only, not flattened to the NIF's root. Bethesda's articulated props
commonly place the actual positioning/pivot offset on an *intermediate* `NiNode`
(a hinge or lift node) one or more levels above the renderable geometry — so any
object using this authoring pattern had that offset silently dropped.

**Confirmed against real data**, not assumed, via a throwaway diagnostic (dumped the
raw `nifly` block hierarchy directly, bypassing our own loader) against
`Clutter\Fridge\FridgeClosed01.NIF` (`RefrigeratorWithFood`'s model):

```
[0]  BSFadeNode "FridgeClosed01"              (root)
[18]   NiNode "FridgeClosed01 NonAccum"       local=(0, 0, 0)
[19]     NiNode "FridgeContainer"             local=(0.39, -0.89, 73.59)   <- body pivot
[24]       NiTriStrips "FridgeContainer:0"    local=(0, 0, 0)              <- body mesh
[30]     NiNode "FridgeDoor"                  local=(31.07, -12.93, 73.59) <- door hinge
[35]       NiNode "FridgeHandle01"            local=(-52.71, -4.27, 12.72) <- handle pivot (2 levels deep)
[37]         NiTriStrips "FridgeHandle01:0"   local=(22.03, 16.31, -12.72) <- handle mesh
[41]     NiTriStrips "FridgeDoor:0"           local=(-30.68, 12.04, 0)     <- door mesh
```

The body mesh's own local transform is identity — its entire real position (the
`Z=73.59` lift, ≈1.05m, that keeps it off the floor) lives on its parent
(`FridgeContainer`), which the old code never read. The handle is nested *two* levels
deep, so it was missing two stacked ancestor offsets, not just one.

**Why collision looked correct while render didn't**: collision is attached directly
to the pivot `NiNode`s themselves (`FridgeContainer`/`FridgeDoor` both have
`has_collision=1`), one level shallower than the render leaf shapes. `av->GetTransformToParent()`
on the collision-bearing node happens to already be the right value at that depth — it's
not that collision extraction did anything smarter, it just doesn't have the extra
level of nesting the render geometry does.

**API note**: `nifly::NifFile::GetNodeTransformToGlobal()` looks like the obvious
built-in tool for this, but tested and rejected — it silently returns `false` for
`NiTriStrips`/`NiShape` leaf blocks in practice, only resolving `NiNode`-type blocks.
The fix instead walks the parent chain manually.

## Fix

Added `flatten_to_root()` in `nif_loader.cpp` (anonymous namespace): walks from the
object up through `NifFile::GetParentNode()` to the root, composing each ancestor's
own `GetTransformToParent()` via `MatTransform::ComposeTransforms()`. Used for both
the render-mesh path (previously `shape->GetTransformToParent()`) and the
collision-extraction path (previously `av->GetTransformToParent()`) — both now go
through the same correct flattening, rather than collision continuing to work by
depth-coincidence.

## Regression found and fixed in the same pass: the file's root transform must be excluded

The first version of `flatten_to_root()` composed *every* ancestor's transform,
including the NIF's own root block. That broke a different, previously-correct class
of object: building-kit architecture pieces (`dungeons\NV_CraftsmanHomesInterior\*`,
used throughout `GSDocMitchellHouse`) now rendered rotated 90° off — spotted by real
interactive inspection, not caught by the screenshot regression check (a wide isometric
render doesn't make a single wall panel's rotation obviously wrong the way it made the
fridge's sinking obvious).

**Root-caused with the same real-data-comparison method**, not patched blind: dumped
the raw hierarchy for two pieces reported broken (`NVCraftsmanRmEndB`,
`NVCraftsmanRmWallExSmB`) and two reported correct (`NVCraftsmanRoom01`,
`NVCraftsmanRmCorInWindowR01`):

```
BROKEN:  [0] BSFadeNode "NVCraftsmanRmEndB"   local_euler(y,p,r) = (0, 0, -90)
CORRECT: [0] BSFadeNode "NVCraftsmanRoom01"   local_euler(y,p,r) = (0, 0, ~0)
```

The broken pieces have a real, nonzero rotation baked directly onto their **root**
block; the correct ones don't. Bethesda's convention (confirmed by this evidence, not
assumed): a NIF's root-block transform is *not* applied when the file is instanced as
a placed object — it's an authoring/export artifact, not part of the object's actual
geometry. The original pre-2.4 code got this right by accident for ordinary
single-level objects (`shape->GetTransformToParent()`, when the shape's parent *is*
the root, never reads the root's own field) — the first `flatten_to_root()` broke that
accidental correctness by composing the root's own transform back in during the
ancestor walk.

**Fixed** by restructuring the walk to stop *before* composing the transform of any
object that has no parent of its own (the true root) — whether that root is
encountered partway up the ancestor chain, or is `obj` itself (the common case for
collision, which is frequently attached directly to the root block). Re-verified
numerically against both regressions simultaneously: `NVCraftsmanRmEndB` now has an
identity basis (matching the correct `NVCraftsmanRoom01`), and the fridge's `~1.05m` Z
lift is still present — one fix, both cases correct.

## Verification

- Full existing test suite re-run (`test_object_registry.gd`,
  `test_phase1_integration.gd`, `test_resource_caching.gd`, `test_terrain_collision.gd`)
  — all pass, no regression.
- `RefrigeratorWithFood` re-rendered from three angles: sits correctly on the floor/
  counter next to the stove, no longer sunk.
- `NVCraftsmanRmEndB`/`NVCraftsmanRoom01` transforms compared numerically post-fix:
  both now identity, consistent with each other and with the fridge fix holding.

## Deliverables

- `flatten_to_root()` fix in `native/src/nif/nif_loader.cpp`, applied to both render
  and collision extraction.
- This write-up.

## Acceptance criteria

- [x] `RefrigeratorWithFood` renders sitting on the floor, not embedded in it.
- [x] Fix confirmed against real block-hierarchy data, not assumed from symptoms alone.
- [x] Applied uniformly to render AND collision extraction (even though collision
      wasn't visibly broken for the cases checked — it was fixed by depth coincidence,
      not by being correct in general, and could break for a differently-nested object).
- [x] No regression in existing test suite.

## What's still open

- Not verified against every articulated prop in the base game — confirmed for the
  fridge specifically. The mechanism (dropped ancestor `NiNode` transforms) is generic
  and the fix is unconditional (applies to every shape/collision object, not
  fridge-specific), so it should generalize, but hasn't been exhaustively checked
  against doors/medboxes/other lidded containers individually.
- This fixes the **rest pose** only — doors/lids still don't actually open. Real
  animation playback (the `NiControllerManager`/`NiTransformInterpolator`/
  `NiTransformData` blocks visible in the fridge's own hierarchy, blocks 3-16) is
  Phase 3 territory (skeleton/animation support), not attempted here.
- **Separate, unrelated bug found during this investigation, not fixed here**: Godot
  silently discards a requested node name on sibling collision, falling back to its own
  `@ClassName@id` auto-name — confirmed directly (`add_child()` with three same-named
  siblings: the first keeps the name, the second and third become `@StaticBody3D@N`).
  `object_registry.gd`'s `_finalize()` names nodes after the **base record's** EditorID,
  which is not unique per REFR — a base record placed multiple times in one cell (e.g.
  `NVCraftsmanRmEndB`, placed 3 times in `GSDocMitchellHouse`) loses its name on the
  2nd/3rd placement. Worth a follow-up: append the REFR's own FormID whenever a
  sibling-name collision is possible, not just when EditorID is empty.
