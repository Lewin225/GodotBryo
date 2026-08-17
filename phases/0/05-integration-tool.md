# 0.5 — Integration: End-to-End Dump Tool

Parent: [Phase 0](README.md)

## Goal

Tie 0.1–0.4 together into the single deliverable that satisfies the Phase 0 exit
criterion: a tool that goes from "a legally-owned FNV install on disk" to "a known
mesh, correctly textured, viewable outside the original game." This is where Phase 0
either validates the whole approach or surfaces a blocking format problem before any
further phases are built on top of it.

## Steps

1. Input: the reference install path (`fresh_nv_copy/` in this project directory,
   `Data/` subfolder holding the ESM/BSA files) and a record identifier (start with
   a hardcoded FormID or EditorID for a specific `STAT` record picked in task 0.2).
   Hardcode this path as the default for Phase 0 tooling rather than requiring it be
   passed every run — it's a fixed reference copy, not a variable input yet.
2. Pipeline:
   - Open `fresh_nv_copy/Data/FalloutNV.esm` (0.2), locate the target `STAT` record,
     read its `MODL` subrecord to get a relative NIF path (e.g.
     `architecture\goodsprings\...nif`).
   - Open the relevant `.bsa` under `fresh_nv_copy/Data/` (0.1), extract that NIF's
     bytes.
   - Parse the NIF (0.3) into geometry + texture path references.
   - For each referenced texture path, extract it from the textures BSA (0.1) and
     decode it (0.4).
   - Emit a glTF (or Godot `.tres`/`.res`) file with geometry and textures bound
     together, plus a log of every step (paths resolved, sizes, any warnings).
3. Load the output in the Godot editor (or a glTF viewer) and visually compare
   against a screenshot or in-game view of the same object.
4. Repeat for a small fixed set of test objects (aim for ~10, chosen for variety:
   different BSA source, different texture format, at least one multi-submesh
   object) to catch inconsistencies a single happy-path object would hide.
5. Write up findings: anything that had to be special-cased, anything that didn't
   match assumptions from the individual sub-tasks, anything flagged as a risk for
   Phase 1 (e.g. "collision data extraction from NIFs needs its own pass before
   Phase 1 collision work starts").

## Deliverables

- `tools/dump_object` (or similar) CLI: `dump_object <fnv_install_path> <form_id>`
  producing a viewable mesh+texture output.
- A short results write-up (`phases/0/results.md`, written once this task is done)
  covering: what worked as expected, what surprised the team, and any scope
  adjustments needed before Phase 1 starts.

## Acceptance criteria

- [x] All items in the [Phase 0 README](README.md) "Definition of done" checklist
      are satisfied by running this tool — see [results.md](results.md).
- [x] At least 10 distinct objects, spanning multiple BSAs and texture formats,
      round-trip correctly — 15/15 auto-selected objects resolved, spanning 3 mesh
      BSA sources (base, `Update.bsa`, a DLC archive) and all 3 DDS variants FNV
      uses (DXT1/DXT3/DXT5). Full numbers in [results.md](results.md).
- [x] The write-up explicitly calls out anything discovered here that changes
      assumptions in the Phase 1 plan — see [results.md](results.md)'s "What changes
      before Phase 1 starts" section (BSA load-order heuristic, Z-up/Y-up conversion,
      collision extraction, multi-master FormIDs).

## After this task

This is the last task in Phase 0. Once its acceptance criteria are met, move to
Phase 1 (static world rendering) — create `phases/1/` following the same pattern
once that phase is ready to be broken down.

**Status: done.** See [results.md](results.md) for the full write-up, including two
real integration bugs found and fixed, and what should change before Phase 1 planning
starts.

## Implementation notes

See [results.md](results.md)'s "Implementation notes" section for `dump_object`'s
usage, candidate-selection strategy, output format, and the independent
`test_integration.gd` GDExtension-side verification.
