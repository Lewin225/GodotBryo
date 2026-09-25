# old/

Retired v0 code, moved out of the Godot project on 2026-09-23. Nothing here is
loaded, parsed or run — `project/` no longer references any of it.

Kept rather than deleted for the same reason `phases/` was kept outside the
repo: these files are the only record of how several formats and systems were
first made to work, and `gamebryo/README.md`'s warning still applies — any
statement in them presented as fact must be rechecked, not believed.

## What is here

| | |
|---|---|
| `gamebryo/` | 41 v0 implementation files — `object_registry`, the actor/record/node tree, `resolver_pool`, the v0 terrain builder and grass |
| `tests/` | 37 tests whose subject was v0 |
| `_diag/` | 18 one-off diagnostic scenes |
| `Old Viewer Scenes/` | 4 editor viewers built on the v0 registry |
| root | `cell_loader.gd`, `cell_stream_builder.gd`, `world_streamer.gd` — the v0 streamers, superseded by `CellStreamerV2`/`WorldStreamerV2`/`TerrainStreamer` |

Moved with `git mv`, so history is intact and any file can be brought back with
a single `git mv` in the other direction.

## What stayed behind, and why

`project/gamebryo/` still holds 19 files. They fall into three groups:

**Genuinely live, no v1 replacement yet** — `terrain3d_bridge`,
`terrain3d_texture_pool`, `terrain_builder`, `game_time_manager`,
`weather_manager`, `celestial_controller`.

**Imported by the v1 stack** — `inventory` and `face_gen_data` are constructed
by `GodotBryo/Servers/EsmServer/esm_server.gd`; `motion_data` and
`actor_animation_component` are used by `player/player_controller.gd`, where
`MotionData` is an `@export`. These want homes under `GodotBryo/Types/` before
`gamebryo/` can go entirely.

**Still needed by live tests** — `mesh_resolver` (8 tests, including
`tests/servers/test_texture_server.gd`, whose parity check is deliberately
*against* the legacy resolver per TextureServer's README), and `item_node`
(`test_esm_server`).

Plus the transitive closure those pull in: `gamebryo_visual`, `gamebryo_object`,
`gamebryo_reference`, `gamebryo_collision_body`, `gamebryo_rigid_body`,
`face_gen_geometry_asset`, `no_lighting_falloff.gdshader`.

That closure is the lesson from the move itself: the first pass kept
`mesh_resolver` but moved seven files it depends on, which broke compilation
across the whole project. The symptom was tests appearing to hang rather than
fail, because a parse error in a depended script stalls the scene before it
prints anything.

## Closure, twice

Two rounds of breakage came from moving a file without moving what depended on
it, or keeping a file without keeping what it depends on:

1. `mesh_resolver` was kept as a blocker but seven of its dependencies moved
   (`gamebryo_rigid_body`, `gamebryo_visual`, `gamebryo_object`,
   `gamebryo_reference`, `gamebryo_collision_body`, `face_gen_geometry_asset`,
   `no_lighting_falloff.gdshader`). Compilation failed project-wide.
2. The three v0 root streamers moved, but the tests and diagnostics that drive
   *them* were not re-scanned, so `test_world_streamer`, `test_cell_loader`,
   `test_game_loader_injection`, `test_game_character_cache`,
   `test_script_engine_integration`, `test_terrain_streamer_phase3_object_budget`
   and two `_diag` scenes were left pointing at absent classes.

Both presented as tests hanging rather than failing: a parse error in a depended
script stalls a scene before it prints anything, and `timeout` then discards the
buffered output. Check compilation directly (`--headless --editor --quit`, or
run one scene unbuffered) before believing a hang.

## Removing more

Work backwards from the three groups above, not from this folder. A file here
only comes back if something in `project/` genuinely needs it — and if that
happens, the right move is usually to port the caller instead.
