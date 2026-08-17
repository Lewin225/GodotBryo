# 1.1 — Object-Type Registry

Parent: [Phase 1](README.md)

## Goal

Widen 1.0's STAT-only placement to every confirmed-shape type in
[object-types.md](object-types.md)'s Tier 1 (`FURN`, `CONT`, `ACTI`, `DOOR`, `MISC`,
`WEAP`, `ARMO`, `AMMO`, `BOOK`, `KEYM`, `ALCH`, `NOTE`, `TREE`, `MSTT`, `TACT`,
`TERM`, `CCRD`, `IMOD`, `CMNY`), plus `SCOL` (Static Collection) unpacking, by
implementing the layered node design and factory-dispatch registry from
[architecture.md](architecture.md). This is the task that actually builds the
architecture already designed — read that doc first, this one is the implementation
plan for it.

## Format notes

Already confirmed by direct record inspection (see architecture.md's evidence table):
`STAT`/`DOOR`/`CONT`/`ACTI`/`FURN`/`MISC` all lead with `EDID` → `OBND` → (optional
`FULL`) → model data, in that order. That pattern is assumed to hold for the rest of
Tier 1 (`WEAP`/`ARMO`/`AMMO`/`BOOK`/`KEYM`/`ALCH`/`NOTE`/`TREE`/`MSTT`/`TACT`/`TERM`/
`CCRD`/`IMOD`/`CMNY`) based on the strength of the six-type sample, but each should be
spot-checked against fopdoc during implementation rather than assumed silently —
cheap to verify, and this doc's confidence is "strong pattern," not "exhaustively
checked."

`SCOL` structure confirmed via fopdoc: an `ONAM` (FormID of a `STAT`) + `DATA`
(position/rotation/scale local to the collection) per part, repeated for each bundled
static. A `REFR` placing a `SCOL` expands into N placements, each composing the
part's local transform with the outer `REFR`'s transform.

## Steps

1. Implement the `GamebryoReference` → `GamebryoObject` → `GamebryoVisual` layering
   from architecture.md as the actual data structures (whether GDExtension C++
   classes or GDScript — pick based on what's simplest to wire into the registry,
   doesn't need to match native/ vs project/ 1:1 with existing modules).
2. Implement the registry: `type_tag -> factory` map, populated via explicit
   registration, plus the tiered fallback from architecture.md's "Registry
   extensibility" section (registered factory → structural `OBND`+`MODL` fallback →
   skip-with-log).
3. Register one shared default factory for every Tier 1 type — this should be nearly
   all of them, since their record structure and construction (mesh + collider
   placeholder) are identical to `STAT`'s.
4. Implement `SCOL` as its own factory: unpack parts, place each as an ordinary
   `GamebryoVisual`-shaped node under a `Node3D` transform anchor.
5. Extend 1.0's cell-children walk to stop skipping non-`STAT` types — route every
   resolved `REFR` through the registry instead.
6. Re-test `GSDocMitchellHouse`: it should now render its furniture, containers, and
   fixtures, not just static scenery.

## Deliverables

- The registry implementation + `GamebryoReference`/`Object`/`Visual` types.
- Factory registrations for every Tier 1 type + `SCOL`.
- Updated test scene showing `GSDocMitchellHouse` with its full non-actor object
  complement rendered.

## Acceptance criteria

- [x] Every Tier 1 type present in the test cell(s) renders correctly — spot-checked
      4 more types (`WEAP`, `MSTT`, `TACT`, `TREE`) against fopdoc during
      implementation (10 real types confirmed total, including the six from
      architecture.md), all matching the `EDID`→`OBND`→(`FULL`)→model pattern. In
      `GSDocMitchellHouse`: `DoorNode`×2, `ContainerNode`×11, `ActivatorNode`×7 (the
      remaining 4 `ACTI` refs are genuinely meshless invisible triggers — confirmed
      by direct inspection, not a bug — see Implementation notes),
      `FurnitureNode`×14, and 369 objects across every other Tier 1 type (`WEAP`,
      `ARMO`, `ALCH`, `MSTT`, ...) via the structural fallback. 403/434 total refs
      built, 31 correctly skipped: `SOUN`×2 (no mesh, as expected), no-mesh `ACTI`×4
      (genuine invisible triggers), and all 25 `LIGH` refs — checked directly, and in
      this specific cell every one is a pure light source with an empty `MODL`
      (named `OfficeLightAmbWarm`/`OfficeLightFillWarm`/`OfficeLightKeyNeutral`, a
      three-point ambient/fill/key rig), not a fixture-bearing light. So `LIGH`
      isn't exercising the structural fallback here at all — it's correctly falling
      through to skip, same as `SOUN`. (Architecture.md's claim that `LIGH` has
      model data is still true in general — confirmed via its `DATA`/model
      subrecord order — just not for any of this room's specific lights. Worth
      re-checking against a cell with fixture-bearing lights once 1.3 needs one.)
      Visually confirmed via real render: a fully furnished room (rugs, furniture,
      cabinets, fixtures), not just bare walls — but currently unlit beyond the
      demo scene's own flat directional sun, since none of the room's 25 real light
      sources render or emit light yet.
- [x] `SCOL` objects expand into their constituent statics with correct nested
      transforms — `SLGoldMine01INT` (found via a standalone probe, not hand-picked)
      has 3 real `SCOL` refs; all 3 unpacked correctly (1 part each in this cell),
      each part a proper `GamebryoVisual`-shaped node, visually confirmed via real
      render (mine-cart rail track segments, correctly textured and placed).
- [x] An unregistered/unknown type with `OBND`+`MODL` still renders via the
      structural fallback — demonstrated deliberately as specified: `DOOR` (a
      registered type) built as `DoorNode` while registered, unregistered, confirmed
      it still resolved to a plain `GamebryoVisual` (not `DoorNode`, not null) via
      the fallback, then re-registered and confirmed it went back to `DoorNode`. Also
      exercised naturally and at scale by every unregistered Tier 1 type (369 objects
      in the same test run), not just the contrived case.
- [x] A genuinely unhandled type (no mesh) is skipped with a log line, not a crash —
      used `SOUN` (real data: 2 refs in `GSDocMitchellHouse`, confirmed no `MODL`)
      rather than the doc's original `ASPC` suggestion, since `SOUN` was the type
      actually present in the test cell.

## Explicit non-goals for this task

- `LIGH` — confirmed to need more than the shared shape (a real light), gets its own
  task: [1.3](03-light-sources.md).
- Real collision shapes — [1.2](02-collision-extraction.md), can land independently.
- Interactive/gameplay behavior for any type (open/closed state, lock difficulty,
  script hooks) — Phase 1's benchmark is correct placement, not interaction. Adding
  those fields later is expected to be routine incremental work per
  architecture.md's "typed node vs. generic node" decision rule, not a redesign.
- `TXST`/`ARMA` as direct `REFR` targets — still flagged as needing research in
  object-types.md; handle via the structural fallback (or skip) rather than blocking
  this task on resolving them.

## Implementation notes

- **Layering implemented in GDScript** (`project/gamebryo/`), not GDExtension C++ —
  architecture.md deliberately left this open. GDScript's `class_name` gives real
  inheritance (`GamebryoReference` → `GamebryoObject` → `GamebryoVisual` →
  `DoorNode`/etc.) without needing to touch the native build, and the registry's
  `Callable`-based dispatch is natural in GDScript. `GamebryoReference` extends
  `StaticBody3D` (not `Node3D`) from the base of the chain — an inert `StaticBody3D`
  with no shape yet is harmless, and it means no subclass needs to change its engine
  base type once [1.2](02-collision-extraction.md) adds real `CollisionShape3D`
  children.
- `GamebryoObject`'s `bounds` field (the real `OBND` struct) was **not** added despite
  being part of the documented layering — `get_cell_references()` doesn't parse
  `OBND` at all yet, and an always-zero field would be worse than no field. Added
  `editor_id`/`record_type` only, since those are actually populated. Revisit if
  something needs real bounds (culling, icon framing) later.
- The registry's structural fallback (tier 2) keys off `model` (MODL) presence alone,
  not `OBND` presence, for the same reason — `OBND` isn't in the resolved placement
  Dictionary at all. Every type checked so far that has `MODL` also has `OBND`, so
  this is a safe simplification in practice, just worth being explicit that it's a
  simplification rather than a literal implementation of architecture.md's wording.
- Only 4 dedicated leaf classes were written (`DoorNode`, `ContainerNode`,
  `ActivatorNode`, `FurnitureNode` — the ones actually named during Phase 1 planning
  discussion), each with zero fields beyond `GamebryoVisual`. The other 14 Tier 1
  types deliberately have **no** dedicated class and are never registered — they run
  entirely through the structural fallback, instantiating plain `GamebryoVisual`.
  This wasn't a corner cut: it's the direct, intended consequence of
  architecture.md's registry design (register a type only when it diverges), and it
  means the fallback path is exercised by the large majority of real placements in
  every test run, not just the one contrived unregister/re-register demo the
  acceptance criteria specifically asked for.
- **`GamebryoMeshResolver` (`project/gamebryo/mesh_resolver.gd`) extracted as shared
  infrastructure** — the BSA-priority-search + NIF/DDS resolution logic had been
  independently duplicated across five scripts by this point
  (`test_integration.gd`, `test_dds.gd`, `test_interior_cell.gd`, `cell_viewer.gd`,
  `cell_viewer_editor.gd`). Factories genuinely need this logic, so extracting it now
  is directly motivated, not speculative reuse — see the project's general guidance
  against premature abstraction, which this doesn't violate since the need is real
  and immediate. `cell_viewer.gd`/`cell_viewer_editor.gd` were updated to use the
  real registry (replacing their original ad hoc "any REFR with a model" heuristic
  from when they were built, before 1.1 existed) and shrank considerably as a result.
  `test_interior_cell.gd` (1.0's formal STAT-only test) was deliberately left
  untouched — it documents 1.0's specific claim and shouldn't change meaning
  underneath it.
- **Two bugs found and fixed while writing the test scene, not the registry itself**:
  (1) a GDScript static-type-inference error (`var cls := A if cond else B` where `A`
  and `B` have different types) that prevented the script from loading at all — the
  window opened but stayed blank forever with no visible error unless stdout was
  checked; (2) the test's screenshot function set up the camera but never actually
  called `save_png()` or awaited a frame, so it silently "succeeded" while writing
  nothing — caught by checking the output file actually existed. Separately, the
  first screenshot attempt (after fixing the above) was blank because this script
  computes its AABB from `global_transform` (which already includes the scene root's
  Z-up→Y-up rotation), then additionally applied the manual `(x,z,-y)` axis remap
  used in `test_interior_cell.gd` (where the AABB is built from local,
  *pre-rotation* transforms) — double-converting the camera target. The two scripts
  compute their AABBs in different spaces and need different framing math; this is
  now commented at both call sites to avoid copy-pasting the wrong one next time.
- Test harness: `project/test_object_registry.gd` / `test_object_registry.tscn`, run
  the same way as every other visual-check task (`DISPLAY=:0
  tools/Godot_v4.7.1-stable_linux.x86_64 --path project test_object_registry.tscn
  --resolution 1200x900`).
- Not chased down, noted for later: a handful of objects in the `GSDocMitchellHouse`
  render show as plain white/untextured panels (plausibly paintings/picture frames —
  `TornPaintingLg03`, `EmptyFrameBack` and similar were among the STAT list found in
  1.0) rather than a placement or registry bug. Doesn't block this task's acceptance
  criteria; worth a look whenever texture-path edge cases are revisited.
