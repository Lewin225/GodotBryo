# terrain_streamer: heap corruption on shutdown — RESOLVED

**Cause:** the loaded `libterrain_streamer*.so` was stale, built against an obsolete `EsmFile`.
Diagnosis and evidence: [`heap_corruption_problem_report.md`](heap_corruption_problem_report.md).

This file was the original investigation brief. Its three leads — a static `shared_ptr` cache
lifetime, an under-guarded mutex, and two copies of the ESM translation units in one process — were
all **wrong**, and are recorded here only so nobody re-derives them. They are superseded.

## What actually happened

`native/terrain_streamer/SConstruct` compiles its own sources **plus** `../src/esm/esm_file.cpp` and
`../src/common/*.cpp`. The shipped `.so` predated a change to `native/src/esm/`, so it carried an
`EsmFile` whose destructor closed a `FILE *` and walked an internal tree — a class layout the
current source cannot produce (it owns a `std::vector<uint8_t>` and reads the file into memory).
The shutdown crash was that obsolete destructor.

**The brief's staleness check was the error.** It compared the `.so` timestamp against
`native/terrain_streamer/src/*` only, found the binary newer, and concluded "not stale" — having
already noted, one paragraph earlier, that the build also pulls in `native/src/esm/`. One of three
inputs was checked and the conclusion stated with confidence. The other two inputs were the answer.

## Outcome

`SConstruct` had two defects that stopped the documented rebuild from running at all: it called
`subprocess.run()` with no `import subprocess`, and `_strip_quotes()` was used but never defined.
Both are fixed, and the documented command now completes including the chunked `ar` path.

After a canonical rebuild, three of the six scenes pass. The heap corruption signature
(`malloc_printerr` / `_int_free_chunk` with `libterrain_streamer` frames) is gone from all of them.

The other three fail for three unrelated reasons, none of them memory corruption:

| scene | status |
|---|---|
| `test_terrain_streamer_phase2_stress` | passes |
| `test_terrain_streamer_phase3_completion` | passes |
| `test_terrain_streamer_phase4_retention` | passes |
| `test_terrain_region_stager` | `ALL CHECKS PASSED`, then aborts on the `EsmServer` thread race below |
| `test_terrain_streamer_phase1` | real assertion failure: `TerrainStreamer is a scene-authored Game sibling` |
| `test_terrain_streamer_phase3_object_budget` | perf assertions: construction p95 and max outside 10% of the Phase 1 baseline |

The last two are genuine open failures and are nothing to do with this incident.

## Standing hazard

`project/addons/terrain_streamer/bin/*.so` is gitignored build output, so its timestamp says nothing
about which sources it was built from. Treat it as stale whenever **any** of these change:

- `native/terrain_streamer/`
- `native/src/esm/`
- `native/src/common/`

A timestamp comparison cannot establish source/artifact compatibility. This is the same class of
gotcha `AGENTS.md` already records for `nv_engine` — a gitignored `.so` that a `git pull` never
rebuilds, failing silently rather than loudly.

## Separate, still open

`EsmServer` (`project/GodotBryo/Servers/EsmServer/esm_server.gd`) starts a `Thread` in `_ready()`
and only calls `wait_to_finish()` from `_process` once it is already finished, so a scene quitting
early destroys a running `Thread` and aborts. Verified directly: a scene that awaits one frame and
quits aborts on `master`. This is what `test_terrain_region_stager` now hits, and it accounts for
the `134` exits that move between scenes run to run (`test_tri`, `test_editor_marker_filter`).

`EsmServer/` is only ever changed as its own task, so it is not fixed here.
