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
| `test_terrain_streamer_phase1` | `ALL CHECKS PASSED`, then aborts: `SIGSEGV` in `__pthread_mutex_lock`, its own bug |
| `test_terrain_streamer_phase3_object_budget` | perf assertions: construction p95 and max outside 10% of the Phase 1 baseline |

`phase3_object_budget` is a genuine open failure and nothing to do with this incident: construction
p95 is 3.239 ms against a 2.402 ms budget, and max is 242.497 ms against 14.95 ms — 16x over, which
points at one pathological construction rather than a uniform slowdown. It is not the NifServer tree
cache: with `use_nif_server=false` it still fails at 2.868 ms / 186.423 ms.

`phase1` previously also failed an assertion that matched `game.tscn` for the exact string
`[node name="TerrainStreamer" type="Node3D" parent="."]`. The editor has since written that line as
`parent="." unique_id=842013845`, so the literal match failed while the node itself was correct and
correctly parented. The assertion was dropped rather than repaired: TerrainStreamer, WorldStreamer
and CellStreamer are the remaining v2 work and the scene layout it pinned is about to change. The
rest of the scene's checks — readiness supersession, the WorldStreamer/terrain decoupling rules, and
the transition-release logic — still run.

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

This has since been fixed: `EsmServer._exit_tree()` now joins the load thread, taking the suite from
17 failing scenes to 8 and clearing `test_terrain_region_stager` among ten others.

**`test_terrain_streamer_phase1` was not this bug**, and still aborts after passing every assertion.
It was attributed to the `EsmServer` race on the strength of a shared `134` exit status, without
reading its stack. Its crash is a `SIGSEGV` inside `__pthread_mutex_lock` — a use-after-free of a
mutex, the same signature class as the rejected NifServer threaded duplication, and unrelated to
`Thread` destruction. Still open.
