# Phase 1 — Results

Parent: [Phase 1](README.md)

Written on completion of [1.5](05-integration.md), the last Phase 1 sub-task. Covers:
what worked as expected, what surprised us, and what changes before Phase 2 planning
starts.

## Definition of done — final status

From [phases/1/README.md](README.md), checked against the combined 1.5 run
(`project/test_phase1_integration.gd`) rather than each sub-task's own isolated test:

- [x] A default interior cell (`GSDocMitchellHouse`, FormID `00103DF9`) loads with
      correct static geometry, correct textures, and walkable collision — 428/434 refs
      built, 431 collision shapes present, confirmed by both the earlier per-task tests
      and this combined run (screenshot: `phase1_integration_interior.png`).
- [x] Interior cells are loadable generically by EditorID or FormID, not just the
      hardcoded default — `RanchHouseInterior03` (1.0/1.1's existing second cell) loads
      26 objects through the exact same code path in the same session as the default.
- [x] `FURN`/`CONT`/`ACTI`/`DOOR` and the rest of the confirmed-shape object types
      render alongside `STAT` in the same cell, each its own typed node — confirmed via
      `by_class` histogram in the combined run.
- [x] `LIGH` records produce real, correctly-placed Godot light sources — 25 `LightNode`
      instances in the default interior cell alone.
- [x] A default exterior cell (Goodsprings, `WastelandNV` (-17, 0)) loads with heightmap
      terrain, splatted ground textures, and placed static objects — 108/115 refs built,
      terrain present (screenshot: `phase1_integration_exterior.png`).
- [x] Collision is walkable in both the interior and exterior default cells — interior
      collision shape count (431) confirmed non-zero before the exterior cell is even
      added, and the combined scene's total collision shape count strictly increases
      once the exterior's terrain + object collision is added on top.
- [x] Unsupported/unregistered reference types are skipped with a log line, not a
      crash — `SOUN` (no `MODL`) skipped cleanly in the interior; `ACRE` (actor/creature
      placement) confirmed present in the exterior cell's raw child census but correctly
      excluded before ever reaching the registry (see "What surprised us" below).
- [x] A basic free-fly/no-clip camera controller exists (`project/free_cam.gd`) — proven
      to actually move and turn via simulated `InputEventKey`/`InputEventMouseMotion`
      events rather than just existing unused: holding W for 1 simulated second moved
      the camera ~3.4m (expected ~4m at `move_speed=4.0`), and injected mouse motion
      changed camera yaw by 0.6 rad.

**All Phase 1 exit criteria are met.**

## 1.5 run: both default cells + generic lookup + fallback paths, one session

`project/test_phase1_integration.gd` (see [05-integration.md](05-integration.md)) runs
the full pipeline once, in this order, all through `GamebryoObjectRegistry`/
`GamebryoMeshResolver`/`GamebryoTerrainBuilder` (1.1–1.4's actual production code, not
the ad hoc per-task BSA/NIF/DDS calls 1.0's own test still uses):

```
built=428/434 skipped=6 skipped_types={ "ACTI": 4, "SOUN": 2 }
[interior] collision shapes: 431
[exterior] found (-17, 0): LAND yes, terrain yes, objects built=108/115
[generic]  second interior "RanchHouseInterior03": built=26
[generic]  second exterior found at (-19, -2)
[fallback] DOOR unregister -> GamebryoVisual -> re-register -> DoorNode: all pass
[fallback] Goodsprings cell child census: { "LAND": 1, "NAVM": 1, "REFR": 115, "ACRE": 1 }
[camera]   W held 1s -> moved 3.41m; mouse dx=200 -> yaw delta 0.6 rad
ALL CHECKS PASSED
```

Run non-headless (`DISPLAY=:0 tools/Godot_v4.7.1-stable_linux.x86_64 --resolution
1200x900 test_phase1_integration.tscn`) — headless mode can't drive an actual render,
same limitation noted since 0.4. Two screenshots confirm the visual result: Doc
Mitchell's house with its roof cutaway showing furniture/containers/doors/lights all
correctly placed, and Goodsprings' saloon/store/road/fence sitting on textured sloped
terrain, matching 1.4's own screenshot.

## What surprised us

1. **Goodsprings' own cell has no `ACHR` (human NPC) placements, but does have one real
   `ACRE` (creature).** 1.5's spec named `ACHR` specifically as the type to
   deliberately trigger the "genuinely unhandled, skip with a log" fallback path. The
   assumption that the default exterior cell would contain `ACHR` turned out to be
   wrong — checked by adding a small new binding
   (`EsmReader::get_cell_child_type_counts()`, a census of every `CELL` child record
   type, not just the `REFR`s `get_cell_references()` already resolves) and reading the
   real data instead of assuming. Goodsprings' human NPCs (Sunny Smiles, Trudy, etc.)
   are evidently not placed via a raw `ACHR` in this specific cell's own record. `ACRE`
   is the same actor-placement family per
   [object-types.md](object-types.md#L89) and was genuinely present (1 in this cell),
   so it was used instead — same finding either way: **actor/creature placements are
   filtered a full layer below the object registry**, inside
   `EsmFile::get_cell_references()` itself (`native/src/esm/esm_file.cpp`'s `if
   (child.type != "REFR") continue;`), not by the registry's own fallback tier. The
   registry never sees an `ACHR`/`ACRE` placement Dictionary at all — there is nothing
   for it to skip. This is arguably the more correct place for the exclusion (Phase 1
   never claimed to handle actors, and filtering at the ESM boundary means every
   caller — registry, future tools, anything else built on `EsmFile` — inherits the
   correct behavior automatically, the same "fix at the true source" reasoning
   documented throughout this project), but it does mean the *specific* fallback path
   1.5 named doesn't literally exist at the layer 1.5 expected to find it in. Worth
   flagging explicitly rather than silently substituting `ACRE` and moving on.

2. **The two hardcoded-default-cell acceptance criteria (interior + exterior) were
   already independently proven by 1.0–1.4's own tests before 1.5 started** —
   1.5's actual, non-redundant contribution was catching the gaps between them:
   confirming they *coexist* in one running scene without interfering (no leftover
   global state between the interior and exterior load paths, no camera/lighting
   singleton conflicts), confirming the free-fly camera controller (built ad hoc back
   in 1.0's early tooling, reused silently by every visual test since, but never
   actually exercised as a claimed deliverable) truly responds to input rather than
   just being present in the scene tree, and surfacing the `ACHR`/`ACRE` layering
   finding above that no single sub-task's own test would ever have hit.

3. **No new bugs were found in the shared pipeline code itself.** Every 1.0–1.4 bug
   (the VHGT offset scale, the `HeightMapShape3D` dead end, the REFR rotation sign, the
   `MODL` path prefix inherited from Phase 0, etc.) was already found and fixed at the
   true source during its own sub-task. 1.5 running everything together in one process
   surfaced zero regressions — a reasonable signal that "fix at the true source, not
   per-consumer" has actually been followed consistently through the phase, not just
   claimed.

## What changes before Phase 2 planning starts

- **World streaming needs deferred block/sub-block coordinate lookups.** Phase 1's
  `find_exterior_cell(wrld_form_id, x, y)` does a direct scan for one specific `XCLC`
  grid coordinate — fine for loading exactly the cells asked for, once, per Phase 1's
  own explicit no-streaming scope. Phase 2 (continuous multi-cell streaming) will need
  real block/sub-block group traversal (`WRLD` → block `GRUP`s → sub-block `GRUP`s →
  cells) to enumerate *which* cells exist near a moving player efficiently, rather than
  probing individual coordinates. This 1.5 run's own "scan a 5×5 neighborhood to find a
  second exterior cell" (used purely to demonstrate generic lookup) is a preview of
  exactly the naive approach that won't scale to real streaming — it took a brute-force
  scan of 24 coordinate probes to find one populated neighbor.
- **`ACHR`/`ACRE` (actor/creature placement) is fully unhandled, confirmed present in
  real default-cell data, and currently silently dropped one layer below anything Phase
  1 code can see or log.** Not a bug (explicitly out of scope per ROADMAP.md — "No
  NPCs, no AI"), but Phase 2+ (whichever phase reintroduces actors) will need to either
  thread `ACHR`/`ACRE` through `get_child_records()`/`get_cell_references()`'s existing
  REFR-only filter or add a parallel accessor, since the exclusion currently lives
  inside `get_cell_references()` itself rather than at a layer a future actor-loading
  system could easily opt back into.
- **`get_cell_child_type_counts()` is a new, small, generically useful binding** (added
  during 1.5, not scoped to any earlier task) — a full census of a cell's child record
  types, independent of whichever subset any given consumer currently resolves. Worth
  keeping in mind as a debugging/verification tool for Phase 2's streaming work too
  (e.g., confirming a cell's full record-type makeup before deciding how to handle it),
  not just this one-off use.
- **Terrain3D adoption timing**: not evaluated this phase. 1.4's terrain
  (`GamebryoTerrainBuilder`) is a from-scratch `ArrayMesh`/`ConcavePolygonShape3D`
  builder, deliberately scoped to "one cell, loaded once" — adequate for Phase 1's
  no-streaming exit criterion, but Phase 2 planning should explicitly decide whether to
  keep extending this approach (LOD, seamless quadrant stitching across cell
  boundaries, streaming load/unload) or adopt a dedicated terrain plugin at that point,
  rather than the decision happening by default via inertia.
- **`HeightMapShape3D` does not function in this engine build/configuration** (Godot
  4.7.1, default physics backend) — confirmed via an isolated minimal repro in 1.4, not
  deeply root-caused beyond that. Worth a note for whoever next reaches for it in this
  project; `ConcavePolygonShape3D` is the proven-working alternative for any static
  trimesh collision going forward.
- **Continuous collision detection (`continuous_cd`) is required for small/fast bodies
  against terrain**, found via 1.4's physics drop test (tunneling through a
  zero-thickness trimesh). Any future projectile/fast-object system landing on terrain
  inherits this requirement — worth documenting as a project-wide convention before
  Phase 2/3 adds moving objects that could hit terrain at speed.

## Implementation notes

- `project/test_phase1_integration.gd` / `.tscn` — the combined 1.5 scene/test. Reuses
  `GamebryoMeshResolver`/`GamebryoObjectRegistry`/`GamebryoTerrainBuilder` throughout
  (no hand-rolled BSA/NIF/DDS code, unlike 1.0's own older test). Run non-headless:
  `DISPLAY=:0 tools/Godot_v4.7.1-stable_linux.x86_64 --resolution 1200x900
  test_phase1_integration.tscn` (from `project/`).
- `native/src/esm/esm_reader_gd.{h,cpp}` — added `get_cell_child_type_counts(cell_form_id)
  -> Dictionary` (record type -> count), used to demonstrate the `ACHR`/`ACRE`
  exclusion finding above. Thin wrapper around the existing `EsmFile::get_child_records()`
  C++ helper (already used internally by `get_land_data()`), no new C++ logic beyond
  the binding itself.
- `project/free_cam.gd` — no changes; already existed since early in Phase 1 as
  incidental tooling infrastructure. 1.5 is what actually turns it into a verified
  deliverable rather than an unexercised convenience script.
- Screenshots: `phase1_integration_interior.png`, `phase1_integration_exterior.png`.
