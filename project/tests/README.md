# Tests

Every `test_*.gd`/`test_*.tscn` pair in this directory is a real, standalone Godot scene
that exercises this project's native GDExtension classes (`EsmReader`, `BsaReader`,
`NifReader`, `GamebryoMeshResolver`, `WorldStreamer`, ...) against the real shipped game
data — not mocks, not synthetic fixtures. Most are headless, self-checking, and exit on
their own with a pass/fail status; a few are interactive visual-inspection scenes (see
"Interactive / visual tests" below).

## Running a test

**Use the project's own native Godot binary, not the system flatpak.** The flathub
`org.godotengine.Godot` flatpak's bundled runtime ships an older glibc than this host's
compiler targets — a GDExtension `.so` built with the host toolchain fails to `dlopen()`
inside it. See `native/README.md` for the full explanation. The correct binary:

```
tools/Godot_v4.7.1-stable_linux.x86_64
```

From the `project/` directory:

```
../tools/Godot_v4.7.1-stable_linux.x86_64 --headless --path . tests/test_bsa.tscn
```

A passing headless test prints a series of `  OK   ...` lines, ends with
`ALL CHECKS PASSED`, and exits with code `0`. A failing one prints `  FAIL  ...` for
each failed check, `FAILURES: N` at the end, and exits with code `1`.

**Run every headless test in one go** (skips the one interactive viewer,
`test_exterior_cell.tscn` — see below):

```
cd project
GODOT="../tools/Godot_v4.7.1-stable_linux.x86_64"
for t in tests/test_*.tscn; do
  [ "$t" = "tests/test_exterior_cell.tscn" ] && continue
  echo "### $t ###"
  timeout 150 "$GODOT" --headless --path . "$t" 2>&1 | grep -E "FAIL|ALL CHECKS|FAILURES"
done
```

Some of these take real wall-clock time against the real ~2.5GB of game data (BSA
scans, full worldspace streaming) — `test_world_streamer.tscn` and `test_cell_loader.tscn`
in particular can take a minute or more. A 150s per-test timeout has been generous
enough in practice; raise it if a slower machine needs more.

**A fresh checkout (or after adding/moving/renaming any test file) needs one
`--headless --editor --quit` pass first** to (re)generate `.uid` sidecar files and the
editor's uid cache — otherwise Godot can't resolve `res://` script/scene references:

```
../tools/Godot_v4.7.1-stable_linux.x86_64 --headless --editor --quit
```

## Known, pre-existing non-failures

Two tests fail (or partially fail) for reasons that are real but out of scope for this
directory's own tests to fix — noted here so a future run isn't mistaken for a
regression:

- **`test_collision.gd` — `Bucket01: collision size within 4x of render mesh size`
  fails** (ratio ≈0.20). A real, standing discrepancy in how tightly that specific
  object's collision hull matches its render mesh — not caused by, or fixed by, any of
  the streaming/LOD work done alongside this test suite. Every other object in that
  test passes the same check.
- **`test_phase1_integration.gd` — the two `free_fly_camera` mouse-look checks fail**
  under `--headless`. Synthetic `InputEventMouseMotion` injection doesn't drive camera
  rotation the same way real mouse input does without a real display/input backend —
  an environment limitation, not a bug in the free-fly camera itself.

Several other tests (`test_dds.gd`, `test_integration.gd`, `test_interior_cell.gd`,
`test_object_registry.gd`, `test_phase1_integration.gd`, `test_terrain.gd`) try to save
a screenshot via `get_viewport().get_texture().get_image()`. Under `--headless`,
Godot's Dummy rendering driver has no real texture to hand back, so this now prints
`(skipped screenshot -- no real viewport texture under --headless, expected)` and
continues — every other check in those tests still runs and still needs to pass. (This
used to crash instead, silently hanging the process forever since the crash happened
before the test's own `get_tree().quit()` call ever ran — fixed by guarding for `img == null`.
Run with a real, non-headless Godot instance if you actually want the screenshot output,
written to `/tmp/nv_test_screenshots/`.)

## Interactive / visual tests

`test_exterior_cell.tscn` is a free-fly-camera viewer (WASD + mouse look), not a
self-checking pass/fail test — it loads Goodsprings' exterior cell and terrain and
waits for a human to look at it and close the window. It has no `get_tree().quit()` of
its own, so it will hang until manually closed (or until an external timeout kills it,
if run in a batch). Run it with a real (non-`--headless`) Godot instance to actually see
anything.

## What each test covers

| Test | Covers | Mode |
|---|---|---|
| `test_bsa` | `BsaReader` — opening/extracting from real shipped `.bsa` archives | headless |
| `test_esm` | `EsmReader` — header, record iteration, STAT→MODL resolution, compressed-record decompression | headless |
| `test_nif` | `NifReader` — real NIF parsing, glTF export for visual cross-checking | headless |
| `test_dds` | DDS/BC1/BC3 texture decoding + material application on a real textured mesh | headless |
| `test_scene` | Native GDExtension sanity check (`NVPing`) — confirms the compiled `.so` actually loaded | headless |
| `test_integration` | 0.5: end-to-end `EsmReader`/`BsaReader`/`NifReader`/DDS pipeline, cross-checked against `native/tools/dump_object` | headless |
| `test_interior_cell` | 1.0: interior cell loader (STAT-only) | headless |
| `test_collision` | 1.2: NIF `bhk*` collision extraction → `Shape3D` | headless (see caveat above) |
| `test_object_registry` | 1.1: base-type → factory dispatch (`GamebryoObjectRegistry`) | headless |
| `test_exterior_cell` | 1.4: exterior cell terrain + placed objects | **interactive viewer** |
| `test_terrain_collision` | 1.4: terrain `HeightMapShape3D` collision (ball-drop settle check) | headless |
| `test_terrain` | 1.4: exterior terrain + objects, screenshot | headless |
| `test_phase1_integration` | 1.5: full Phase 1 pipeline, both default cells (see caveat above) | headless |
| `test_resource_caching` | 2.0: mesh/texture/collision cache hit/miss counters across a repeat load | headless |
| `test_cell_loader` | 2.7: `CellLoader` — interior↔exterior swap, door-triggered load | headless |
| `test_door_activate` | 2.7 step 4: real raycast → `DoorNode` interaction | headless |
| `test_world_streamer` | 2.8/2.12: `WorldStreamer` — activate/upgrade/downgrade/movement-driven load-unload, circular radius, real settle timing | headless |
| `test_resolver_pool` | 2.10 step 2: `GamebryoResolverPool` (per-thread resolve context pooling) | headless |
| `test_threaded_resolve` | 2.10 step 3: `resolve_placement()`/`resolve_tile()` under real `WorkerThreadPool` concurrency | headless |
| `test_exterior_cell_lookup` | 2.11: `find_exterior_cell()`'s block/sub-block index (vs. the old O(worldspace) scan) | headless |
| `test_editor_marker_filter` | Rendering punch-list #4: `EditorMarker` submesh filtering (CK-only gizmo geometry) | headless |
| `test_visible_when_distant` | 2.12 step 1: "Visible When Distant" `REFR` flag exposure | headless |
| `test_lod_companion_path` | 2.12 step 2: `_lod.nif` companion path derivation | headless |
| `test_lod_full_detail_gating` | 2.12 step 3: `full_detail` gating in `resolve_placement()`/`resolve_tile()` | headless |
| `test_lod_raw_geometry` | 2.12 step 4: second raw LOD geometry block attachment | headless |
| `test_lod_geometry_build` | 2.12 step 5: LOD mesh `ArrayMesh`/material building + caching | headless |
| `test_lod_construct_node` | 2.12 step 6: Node-based construct path (`MeshInstance3D` + `visibility_range`) | headless |
| `test_lod_direct_batch` | 2.12 step 7: RID-based construct path (`DirectGeometryBatch` LOD tier) | headless |
| `test_lod_crossover_config` | 2.12 step 8: real configurable crossover distance/margin plumbing | headless |
| `test_terrain3d_spike` | 2.13 step 2: real-cell `VHGT` heightmap import into Terrain3D, bit-exact numeric round-trip + screenshot | headless (screenshot needs non-headless, see caveat above) |
| `test_terrain3d_texture_paint` | 2.13 step 4 (base-texture half): real `BTXT`→`LTEX`→`TXST` quadrant texture painting via Terrain3D's control map, numeric round-trip + screenshot | headless (screenshot needs non-headless, see caveat above) |

Phase/task numbers refer to `phases/`'s own task docs (e.g. "2.12" = `phases/2/12-distant-object-lod.md`).
