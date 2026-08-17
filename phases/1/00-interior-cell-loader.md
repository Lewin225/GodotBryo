# 1.0 — Interior Cell Loader (STAT-only)

Parent: [Phase 1](README.md)

## Goal

Load a single interior `CELL`, place every `STAT`-typed `REFR` in it with correct
transforms, and confirm the whole thing renders correctly in Godot. This is 0.5's
pipeline (ESM → BSA → NIF → DDS) applied to every static object in a real cell instead
of one hand-picked object — the "finish the loop" step, not new format work.

Default target: `GSDocMitchellHouse` (FormID `00103DF9`), but the loader must work by
EditorID *or* FormID generically, not just this one hardcoded cell.

## Format notes

- Interior cells have no `WRLD`/`LAND` — a `CELL` record (interior flag set in
  `DATA`) with a child `GRUP` (type 6, "Cell Children") holding its `REFR`/`ACHR`/etc.
  Confirmed structurally: [fopdoc CELL](https://tes5edit.github.io/fopdoc/FalloutNV/Records/CELL.html).
- **Finding a `CELL` by EditorID/FormID does not require understanding the interior
  cell block/sub-block `GRUP` hashing scheme.** `EsmFile::for_each_record` (0.2)
  already recurses into every `GRUP` regardless of type/label — a full-file scan
  filtering `type == "CELL"` and matching `EDID`/FormID finds it correctly no matter
  which block it's hashed into. Block-based fast lookup (skip straight to the right
  sub-block via its label) is a real optimization but only matters once loading is
  performance-sensitive — Phase 2 (streaming), not here.
- **Getting from a found `CELL` to its `REFR`s**: per TES4-family convention, a
  record's associated child `GRUP` (if any) immediately follows that record's own
  bytes in the file, before the next sibling record. So: locate the `CELL`'s byte
  range end (`data_offset + data_size`), check whether a `GRUP` immediately follows
  there, and if so walk it (recursively — it may itself contain nested
  persistent/temporary/visible-distant sub-`GRUP`s per fopdoc, which don't need to be
  distinguished for Phase 1; collect every `REFR` regardless of which sub-`GRUP` it's
  in).
- `REFR.DATA` (position+rotation) is confirmed at the byte level: `float32[3]`
  position + `float32[3]` rotation, 24 bytes, no padding. `REFR.XSCL` is optional
  `float32`, default 1.0 if absent.
- Resolving `REFR.NAME` → `STAT` → `MODL` → mesh is unchanged from 0.5, including the
  `meshes\` path-prefix fix and the `Subrecord::as_string()` trailing-NUL fix already
  applied at the shared-library level.

## Steps

1. Add a lookup method to `esm::EsmFile` (or a small new helper): find a `CELL`
   record by EditorID (string match against its `EDID`) or FormID.
2. Add a method to get a `CELL`'s child `REFR` records: locate the immediately-
   following `GRUP` (if any) and recursively collect every `REFR` inside it.
3. For each `REFR`, resolve `NAME` → base record; skip (with a log line) anything
   whose base record isn't `STAT` — that's 1.1's job, not this task's.
4. For each resolved `STAT`, run the existing 0.5 pipeline (BSA-priority search →
   NIF parse → texture resolve/decode) and place the result using `REFR.DATA`
   (+ `XSCL` if present) as its `Transform3D`, following
   [architecture.md](architecture.md)'s node shape (`MeshInstance3D` + a collision
   placeholder — real collision is 1.2).
5. Build the cell as a runtime-constructed `Node3D` subtree (per
   [architecture.md](architecture.md)'s "translate, don't replicate" framing) — not a
   pre-baked `.tscn` per cell.
6. Test against `GSDocMitchellHouse` first, then at least one other interior cell
   (pick something small and different — a different building, different BSA
   ancestry) to confirm the EditorID/FormID lookup genuinely generalizes rather than
   being accidentally specific to one cell's structure.

## Deliverables

- `native/src/esm/` additions: cell lookup + cell-children walk.
- A Godot-facing loader (wrapper class or GDScript, following the existing
  `EsmReader`/`BsaReader`/`NifReader` pattern) that takes a cell identifier and
  produces a populated `Node3D`.
- A test scene rendering `GSDocMitchellHouse`, screenshot-verified the same way 0.4/
  0.5's demos were (real GPU render, not just numeric checks).

## Acceptance criteria

- [x] `GSDocMitchellHouse` loads by EditorID and separately by FormID (`00103DF9`),
      producing the same result either way — both resolve to FormID `1064441`
      (`0x00103DF9`), confirmed by a direct equality check in the test scene, not
      just "both non-empty."
- [x] Every `STAT`-typed `REFR` in the cell is placed with the correct transform —
      208/208 STAT placements succeeded with zero failures; visually confirmed via
      real render (see below), showing a coherent room floor plan (walls/floor
      pieces forming actual connected rooms), not scattered/misrotated geometry.
- [x] A second, different interior cell loads correctly via the same generic
      lookup/walk code, with no cell-specific special-casing —
      `RanchHouseInterior03` (found via a quick standalone probe scanning for small
      interior cells, not hand-picked from prior game knowledge), 26/26 STAT
      placements succeeded, visually a completely different, much smaller/elongated
      floor plan, confirming the lookup isn't accidentally specific to the default
      cell's structure.
- [x] Non-`STAT` `REFR`s are skipped with a log line, not silently dropped or
      crashing — `GSDocMitchellHouse` alone has 226 non-STAT refs across 11 other
      types (`MISC`=134, `LIGH`=25, `ALCH`=16, `FURN`=14, `CONT`=11, `ACTI`=11,
      `MSTT`=8, `DOOR`=2, `ARMO`=2, `SOUN`=2, `WEAP`=1), all skipped cleanly with a
      per-type count logged.

## Explicit non-goals for this task

- Every object type beyond `STAT` — that's [1.1](01-object-type-registry.md).
- Real collision shapes — that's [1.2](02-collision-extraction.md); placeholder/no
  collision is fine here.
- Lights — that's [1.3](03-light-sources.md).
- Exterior cells, `WRLD`/`LAND` — that's [1.4](04-exterior-cell-terrain.md).
- Interior block/sub-block hash-based fast lookup — full-scan is fine for Phase 1;
  optimize only when streaming (Phase 2) needs it.

## Implementation notes

- `esm::EsmFile` additions (`find_cell_by_editor_id`/`find_cell_by_form_id`,
  `find_record_by_form_id`, `get_child_records`, `get_cell_references`) and the new
  `ReferencePlacement` struct all live at the same pure-C++, no-Godot-dependency
  layer as the rest of `native/src/esm/` — `get_cell_references` is fully generic
  across base record types as planned, so [1.1](01-object-type-registry.md) reuses
  it unchanged.
- `find_record_by_form_id` builds a one-time `FormID -> RecordInfo` index (lazy,
  cached) rather than a linear scan per lookup — with 208+ REFRs per cell each
  resolving a base record, and later phases resolving many cells, an unindexed scan
  would mean O(refs × file_records) work. This wasn't in the original task plan but
  was clearly necessary once actually implemented against a real 434-reference cell.
- `get_child_records` confirms the TES4-family convention assumed in this doc's
  Format notes: a record's child `GRUP` (if any) immediately follows its own bytes —
  implemented as a peek-and-walk against the existing private `walk()` helper from
  0.2, no changes needed there.
- **REFR rotation sign bug, caught only by interactive inspection, not by the
  automated test.** The first implementation applied Bethesda's rotation
  convention (X/Y/Z Euler radians composed as `Rz * Ry * Rx`) with the raw angles
  from `REFR.DATA`. The automated test's fixed-angle screenshots looked like
  "coherent, non-scattered room geometry" (the acceptance criteria above were
  written and checked off against those screenshots) — but the rotation was
  actually wrong. It only became obvious once a user flew through the cell
  interactively (see `project/cell_viewer.gd` / `cell_viewer_editor.gd`, built as
  ad hoc inspection tools after this task's formal acceptance criteria were
  already checked off): some rotations looked coincidentally fine (single-axis
  cases), others were visibly off, and one-sided architecture panels had their
  only valid face pointing the wrong way — read from outside/above (the
  automated screenshot's angle) as "solid room," but wrong up close. Root cause:
  the angles need to be **negated** before building each per-axis rotation, not
  just composed in the right order. Confirmed by checking OpenMW's actual source
  (an independent, working Gamebryo-era engine reimplementation) rather than
  guessing again — it builds this exact rotation as `Quat(-euler[0], X-axis)`
  etc., then composes `zr*yr*xr`. Fixed in `refr_basis()` in both
  `test_interior_cell.gd` and the viewer tools.
  **Lesson for later phases' acceptance testing: a fixed-angle screenshot from
  outside a structure is a weak check for placement/rotation correctness — it
  can look "coherent enough" while still being wrong. Prefer an interactive
  fly-through (or several angles) before checking off a placement-correctness
  criterion, not just one static render.**
- **NIF triangle winding was backwards, found the same way, and traced back to
  0.3.** Once rotation was fixed, meshes still showed through to their
  backfaces — visible only from inside a room looking at real geometry up close,
  not from 0.3/0.4/0.5's outside-viewed standalone-prop screenshots, which never
  surfaced it. Root cause: `nif_loader.cpp` copied `nifly` triangle indices
  through unmodified; NIF/Gamebryo (DirectX-lineage) winds triangles
  clockwise-front, Godot (and glTF) expect counter-clockwise-front. This bug has
  existed since [0.3](../0/03-nif-parser.md) and affected every mesh loaded
  since, including the glTF exports — just never visually obvious from outside a
  closed convex-ish prop. Fixed at the true source (`nif_loader.cpp`, not
  patched per-caller) by swapping the last two indices of each triangle, so
  every consumer — Godot rendering and glTF export alike — gets correct winding
  from here on.
- Test harness: `project/test_interior_cell.gd` / `test_interior_cell.tscn`, run the
  same way as 0.4/0.5's visual demos (`DISPLAY=:0
  tools/Godot_v4.7.1-stable_linux.x86_64 --path project test_interior_cell.tscn
  --resolution 1200x900` — headless can't drive an actual render, see 0.4's note).
- Caught and fixed a real bug during testing: reusing the demo-camera pattern from
  0.4/0.5 (create a fresh `Camera3D` per scene) silently broke on the *second* cell
  in the same run — Godot only auto-activates a `Camera3D` if none is already
  current, so the second camera was created but never became active, and the
  screenshot silently rendered through the first (now-pointed-at-freed-geometry)
  camera, producing a blank image with no error. Fixed by reusing one camera/light/
  environment across both cells and calling `Camera3D.make_current()` explicitly.
  Worth remembering for any future multi-scene-in-one-run test harness.
- **Interactive inspection tools, built after formal acceptance but kept as
  standing project tooling** (not formally scoped by this task, but valuable
  enough — and directly responsible for catching the two bugs above — to keep
  and document):
  - `project/free_cam.gd` — a generic WASD + mouse-look `Camera3D` script, a
    preview of the controller [1.5](05-integration.md) formally scopes.
  - `project/cell_viewer.gd` / `cell_viewer.tscn` — standalone runtime viewer:
    loads a hardcoded cell (every REFR with a resolvable model, not just
    `STAT`, for a fuller room to walk around), attaches `free_cam.gd`, stays
    open instead of screenshotting-and-quitting like every other test harness.
    Run non-headless: `DISPLAY=:0 tools/Godot_v4.7.1-stable_linux.x86_64 --path
    project cell_viewer.tscn`.
  - `project/cell_viewer_editor.gd` / `cell_viewer_editor.tscn` — `@tool`
    script version: open in the actual Godot editor, select the root node, hit
    the "Load Cell" button in the Inspector (`@export_tool_button`), and the
    cell populates as real, `owner`-set child nodes in the Scene dock —
    inspectable, selectable, and each with a real copyable `NodePath` for bug
    reports, using the editor's own viewport navigation instead of a custom
    camera.
- Second test cell (`RanchHouseInterior03`) was found via a small standalone probe
  (`native/src/esm/esm_file.{h,cpp}` linked directly, no Godot) scanning for interior
  cells with 5–40 references — deliberately not hand-picked from prior game
  knowledge, to keep the "generic lookup" claim honest.
