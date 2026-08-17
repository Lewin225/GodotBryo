# 1.5 — Integration: Both Default Cells

Parent: [Phase 1](README.md)

## Goal

Same role as [0.5](../0/05-integration-tool.md) played for Phase 0: tie everything
together and confirm the phase's actual exit criterion is met, not just each
sub-task's own acceptance criteria in isolation. Load both default cells —
`GSDocMitchellHouse` (interior) and Goodsprings (exterior) — in one pass, satisfying
[ROADMAP.md](../../ROADMAP.md)'s original Phase 1 exit criterion in full.

## Steps

1. Build a basic free-fly/no-clip `Camera3D` controller (mouse-look + WASD) — not the
   real player controller (later phase), just enough to actually walk around and
   inspect the loaded cells interactively instead of relying on fixed demo-script
   camera placement like every prior visual check. Per
   [ROADMAP.md](../../ROADMAP.md)'s original Phase 1 scoping.
2. Run the complete pipeline (1.0–1.4) against both default cells in the same test
   session.
2. Confirm every item in [Phase 1 README](README.md)'s "Definition of done" checklist
   against this real run, the same way 0.5's results.md checked off Phase 0's list
   item by item.
3. Exercise the generic-lookup claim deliberately: load at least one interior cell
   and, if practical, one exterior cell beyond the two hardcoded defaults, purely via
   EditorID/FormID, to prove 1.0's loader isn't secretly cell-specific.
4. Deliberately trigger the registry's fallback paths at least once each (structural
   fallback for an unregistered-but-`OBND`+`MODL`-shaped type; skip-with-log for a
   genuinely unhandled type like `ACHR`) rather than only exercising the happy path.
5. Write up findings the same way [phases/0/results.md](../0/results.md) did: what
   worked as expected, what surprised us, what changes before Phase 2 planning
   starts (world streaming will need the block/sub-block coordinate lookups this
   phase explicitly deferred).

## Deliverables

- A free-fly camera controller.
- A combined test/demo scene (or CLI, if a standalone tool analogous to
  `dump_object` makes sense here — judgment call at implementation time) loading
  both default cells, walkable via the free-fly camera.
- `phases/1/results.md`, following the same honest-accounting format as
  [phases/0/results.md](../0/results.md).

## Acceptance criteria

- [x] All items in [Phase 1 README](README.md)'s "Definition of done" checklist are
      satisfied by this integrated run.
- [x] Both default cells can be walked/flown through interactively with the free-fly
      camera, not just viewed from a fixed demo-script camera position — proven by
      driving the camera with simulated input events and confirming measured movement/
      look-direction change, not just that the controller script exists.
- [x] Generic cell lookup demonstrated on more than just the two hardcoded defaults.
- [x] Registry fallback paths deliberately exercised, not just assumed to work.
- [x] Write-up explicitly calls out anything that changes Phase 2 planning
      assumptions (streaming, the deferred block-coordinate lookups, Terrain3D
      adoption timing, anything else surfaced during 1.0–1.4).

See [results.md](results.md) for the full write-up.

## After this task

This is the last task in Phase 1. Once its acceptance criteria are met, move to
Phase 2 (World Streaming & Scale) — create `phases/2/` following the same pattern,
informed by whatever this phase's results.md flags as changed assumptions.
