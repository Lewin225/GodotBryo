# AGENTS.md

Guide for coding agents (and humans) working in this repository. See also
`ROADMAP.md` (phased plan + current status) and `phases/*/README.md` (per-phase
task docs with real acceptance criteria) for deeper history — this file is the
orientation map, not a replacement for either.

## What this project is

A clean-room engine replacement for Fallout: New Vegas's Gamebryo engine,
built in Godot 4.7. It reads Bethesda's original file formats (ESM, BSA, NIF,
DDS) directly and reproduces observed runtime behavior — in the spirit of
OpenMW, not a decompilation or a mod. It runs against a legally-owned copy of
the game's own data (`fresh_nv_copy/Data/`, gitignored, ~2.5GB) at runtime;
no original assets or code are ever redistributed or embedded in this repo.

## Why this is NOT "run New Vegas in Godot"

That framing undersells (and mis-scopes) the actual project. Concretely:

- **It's an engine, not a mod loader.** There is no NVSE compatibility, no
  third-party mod support, and no Construction Set replacement — those are
  explicitly out of scope until the base title is fully playable (see
  `ROADMAP.md`'s Scope section). The goal is a working replacement for
  Gamebryo itself, using the *original authored data* (ESM records, NIF
  meshes, BSA archives) as the source of truth, not a port of New Vegas's own
  compiled game logic.
- **Fidelity to real, authored data is the hard requirement**, not "close
  enough to look right." Every subsystem here is built by reading the actual
  binary format and cross-checking against real shipped content (see
  `feedback_verify_dont_assume` project convention: never assume a value,
  path, or behavior — verify it against the real ESM/NIF/BSA data or a real
  play session before relying on it). Native offline dump tools (see
  "Native standalone C++ tools" below) exist specifically to make that
  verification cheap.
- **Gameplay systems (AI, combat, dialogue, quests, scripting) are
  deliberately not the current focus.** Phases 0–2 (done) and the early part
  of Phase 3 are about correctly rendering and streaming the actual game
  world and placed objects — actors exist and animate but are currently
  inert. See `ROADMAP.md` for the full phase breakdown and current status.

## Tech stack

- **Godot 4.7.1**, pinned. Use the native standalone Linux binary at
  `tools/Godot_v4.7.1-stable_linux.x86_64` (gitignored — download it
  yourself, see `native/README.md`), **not** the system flatpak — its
  bundled runtime's older glibc can't `dlopen()` a host-built GDExtension
  `.so`.
- **GDExtension (C++)** for format parsing and performance-critical systems
  (`native/src/`, builds to `project/bin/libnv_engine.*.so`).
- **GDScript** for game-logic glue, streaming orchestration, and typed
  gameplay object classes (`project/*.gd`, `project/gamebryo/*.gd`).
- **Terrain3D** (`native/terrain3d/`, vendored submodule) — third-party
  terrain rendering addon, heavily patched (see "Terrain streaming" below):
  its clipmap/LOD/streaming/collision machinery is kept, but its own
  control-map texturing was replaced with a real per-vertex N-layer format
  driven entirely by real BTXT/ATXT/VTXT/VCLR/VNML data.

## Repository layout

```
native/
  src/
    common/      — shared byte-reader/endian helpers
    bsa/         — BSA archive reader (BsaArchive C++, BsaReader Godot wrapper)
    esm/         — ESM/ESP parser (EsmFile C++, EsmReader Godot wrapper)
    nif/         — NIF mesh/collision/animation parser (thin wrapper over
                   vendored nifly/, NifReader Godot wrapper) + a glTF exporter
    gamebryo/    — DirectGeometryBatch (RID-based static geometry batching)
    register_types.cpp/h — GDExtension entry point
  godot-cpp/, nifly/, terrain3d/  — vendored git submodules
  tools/         — standalone C++ diagnostic CLIs, no Godot dependency (see below)
  SConstruct
project/
  game.tscn/.gd            — the real runtime entry point (see "Main scene" below)
  cell_loader.gd           — single-active-cell interior loader
  world_streamer.gd        — continuous exterior worldspace streaming
  cell_stream_builder.gd   — shared per-tile terrain+REFR streaming logic
  gamebryo/                — resolve/construct pipeline + typed object node classes
  addons/fpc/              — first-person character controller (third-party addon)
  addons/terrain_3d/       — Terrain3D addon files (bin/ gitignored, rebuild locally)
  tests/                   — real, self-checking Godot test scenes (see below)
  *_viewer.gd/.tscn        — @tool editor-mode inspection scenes (see below)
  _diag/                   — throwaway one-off diagnostic scenes (a single visual/
                             GPU/shader spot-check, not a reusable tool) -- same
                             "fine to leave uncommitted, fine to commit if it lingers"
                             convention as native/tools/, just GDScript-side
  _repro/                  — throwaway minimal repro scenes for one specific bug
                             investigation, same convention as _diag/
  bin/                     — nv_engine GDExtension build output (gitignored)
phases/                    — per-phase task docs with real acceptance criteria
enginedocs/                — reference notes on file formats / engine behavior
fresh_nv_copy/              — gitignored, your own legally-owned FNV install
tools/                      — gitignored, holds the native Godot binary
```

## Main scene setup

`project/project.godot`'s `run/main_scene` is `res://game.tscn`, script
`game.gd`. Node tree (see `game.tscn`):

- **`Game`** (root, `Node3D`, `game.gd`) — owns the interact raycast, door
  transition routing (interior vs. exterior), player spawn/repositioning,
  and the interior/exterior `WorldEnvironment` swap. Neither `CellLoader` nor
  `WorldStreamer` knows a player exists at all — `game.gd`'s `_process()` is
  the only thing that does, via `_find_character_body()`.
- **`CellLoader`** (`cell_loader.gd`) — single-active-interior-cell loader.
  Used for every interior destination.
- **`WorldStreamer`** (`world_streamer.gd`) — continuous adjacent-tile
  exterior streaming. Purely position-reactive: tracks the active camera,
  not the player body directly. Only one of `CellLoader`/`WorldStreamer` is
  ever "live" at a time; `game.gd` tears down/pauses the other on a
  transition (see `set_paused()` below — entering an interior pauses
  `WorldStreamer` rather than tearing it down, so exterior state survives the
  visit).
- **`Sun`** / **`WorldEnvironment`** — swapped between `interior_environment.tres`
  and `exterior_environment.tres` on every transition (`_set_exterior_environment()`).
- **`Character`** — an instance of the third-party `addons/fpc/character.tscn`
  first-person controller.
- **`Debug Tools`** (`Window`, hidden by default, toggled with the **Home**
  key) — a `TabContainer` of in-game debug panels, see below.
- **`DebugHud`** (`CanvasLayer`) — always-on `CellLabel` (current cell name +
  exterior grid coord) and an F3-toggled `LookAtLabel` (info about whatever
  the camera is currently looking at).

## Core components

**ESM parsing** (`native/src/esm/esm_file.{h,cpp}`, wrapped for GDScript by
`esm_reader_gd.{h,cpp}` as the `EsmReader` class) — reads the TES4-family
GRUP/record/subrecord structure directly from `FalloutNV.esm` (and DLC
masters), decompressing per-record as needed. Exposes typed queries (cell
lookup by EditorID/FormID/grid coordinate, REFR placement resolution, LAND
heightmap+texture-layer data, door XTEL destinations, light data, SCOL part
expansion, LTEX→TXST texture-path resolution, ...) rather than raw
subrecord bytes to most callers. Not thread-safe by design (single `FILE*`)
— every worker-pool context gets its own private `EsmReader` instance (see
`GamebryoResolveContext`).

**BSA archives** (`native/src/bsa/bsa_archive.{h,cpp}`, `BsaReader` wrapper) —
read-only archive reader with case-insensitive path lookup and
decompression. Also not thread-safe per-instance for the same reason.

**NIF parsing** (`native/src/nif/nif_loader.{h,cpp}`, built on the vendored
`nifly` library, `NifReader` wrapper) — extracts static mesh geometry, UVs,
vertex colors, collision shapes (`bhk*` blocks), and animation controller
data (`NiControllerManager`/`NiControllerSequence`) from a parsed NIF. Does
not (yet) handle skeletal skinning.

**Mesh/texture resolution** (`project/gamebryo/mesh_resolver.gd`,
`GamebryoMeshResolver`) — the BSA/NIF/DDS-facing half of turning a REFR
placement into renderable Godot resources. Deliberately split into a
worker-safe **raw resolve** step (`resolve_raw_geometry()`/`load_nif()`/
`_load_image()` — BSA extraction, NIF parsing, DDS decode, all safe off the
main thread) and a **main-thread-only final build** step
(`build_geometry_entries()` — constructs the actual `ArrayMesh`/
`ImageTexture`/`StandardMaterial3D`/`Shape3D` Resources, which touch
RenderingServer/PhysicsServer3D). Caches NIF/texture decodes by path — a
`null` result (not found in any BSA, or found but unparseable) is cached
exactly like a real result and logged via `push_warning()`.

**Object resolution/construction** (`project/gamebryo/object_registry.gd`,
`GamebryoObjectRegistry`) — the base-type dispatch layer: routes a REFR
placement to the right handling (marker, door, SCOL, light, CONT/ACTI/FURN,
or the structural-fallback path for everything else) and produces either a
typed `Node3D` (`DoorNode`/`ContainerNode`/`ActivatorNode`/`FurnitureNode`/
`LightNode`/`MarkerNode`/`GamebryoVisual`, in `project/gamebryo/*_node.gd`)
or feeds a `DirectGeometryBatch` directly (structural-fallback placements —
the overwhelming majority of static scenery — never become individual
Nodes at all, for performance). Also implements the distant-object-LOD gate:
a placement outside the full-detail streaming radius only resolves at all if
its REFR is VWD ("Visible When Distant")-flagged.

**Threaded resolve pool** (`project/gamebryo/resolver_pool.gd`/
`resolve_context.gd`, `GamebryoResolverPool`/`GamebryoResolveContext`) — a
small pool of per-worker-thread contexts (own `EsmReader` + own
`GamebryoMeshResolver`), sized from `OS.get_processor_count()`. Resolve work
runs on `WorkerThreadPool` tasks; only the final Resource-construction/
Node-commit step runs on the main thread. A shared resolver's raw caches are
kept warm across pool contexts via `merge_from()` (deliberately never merges
BSA reader handles — that would reintroduce the exact cross-thread hazard
per-context readers exist to avoid).

**`CellLoader`** (`project/cell_loader.gd`) — loads exactly one interior
cell at a time (its REFRs + any owning-worldspace persistent-cell REFRs),
used for every interior destination and this scene's own initial spawn.

**`WorldStreamer`** (`project/world_streamer.gd`) — continuous
adjacent-grid-cell exterior streaming, parallel to (not replacing)
`CellLoader`. Tracks the active camera's grid coordinate every
`CHECK_INTERVAL_SEC` and maintains a resident tile set using two
hysteresis-guarded radii: `RADIUS_LOAD_FULL` (every placement resolved) and
the wider `RADIUS_LOAD_DISTANT` (VWD-only). `activate(wrld_form_id)` starts
streaming; `deactivate()` tears everything down; `set_paused(bool)` freezes
streaming without freeing anything (used for interior visits — see its own
doc comment in `world_streamer.gd` for why pausing has to separately handle
RenderingServer-visible Nodes, `DirectGeometryBatch`'s raw RID geometry, and
PhysicsServer3D collision, including Terrain3D's own internal collision
body — three genuinely separate layers, not one visibility flag).

**Terrain streaming** (`project/gamebryo/terrain3d_bridge.gd` +
`terrain3d_texture_pool.gd`, on top of the vendored `Terrain3D` addon) —
imports one cell's real LAND heightmap + a real per-vertex N=7 texture-layer
format (base + up to 6 real ATXT overlays per quadrant, real VCLR vertex
colors, real VNML authored normals where present) into a single shared,
persistent `Terrain3D` node per worldspace. `Terrain3DTexturePool` manages a
128-slot real ground-texture budget (normalizing every texture to one
canonical size/format so Terrain3D's own cross-texture validation never
breaks), including real per-texture normal/bump maps (TXST's `TX01` slot).

**Static geometry batching** (`native/src/gamebryo/direct_geometry_batch.{h,cpp}`,
`DirectGeometryBatch`) — RID-based (no Node overhead) static MultiMesh
geometry for the structural-fallback placement path, grouped by mesh
identity. `set_enabled(bool)` toggles visibility for this RID-based content
specifically — it has no Node3D to inherit visibility from.

## Debugging tools

### In-game Debug Tools window

Toggle with **Home** while the game is running (`game.tscn`'s `Debug Tools`
`Window`). Tabs:

- **World Streaming** (`project/world_streaming_debug_tab.gd`) — real-time
  `WorldStreamer` state (active/paused, resident/pending/queued/in-flight
  tile counts, current cell), the load-radius configuration, live-tunable
  `tiles_per_frame`/`objects_per_frame` spinboxes, and the full list of
  ground textures currently resolved into the `Terrain3DTexturePool` with
  their slot usage.
- **Envrioment** (`project/environment_debug_tab.gd`) — the current
  interior cell's real `CELL.XCLL` ambient-lighting data side by side with
  what's actually applied to the live `WorldEnvironment`.
- **Scripting / Quest / Inventory / CellLoader** — placeholder tabs, not yet
  wired up. A planned "ESMReader" tab (mesh/texture/material resource-cache
  hit/miss stats, currently exposed only via `GamebryoMeshResolver.
  get_cache_stats()`) is scoped for one of these, not the World Streaming
  tab — keep that separation when adding to either.

All of these tabs are scene-authored in `game.tscn` (real `Label`/`SpinBox`/
`ItemList` nodes with fixed names) — their scripts only do `@onready $Path`
lookups and refresh logic, deliberately not building UI from code, so the
tab stays an easy place to keep adding controls by hand in the editor.

### Editor `@tool` viewers

Open these scene files directly in the Godot editor (not Play mode) — they
populate real child nodes from real game data live in the editor's own 3D
viewport/Scene dock, no running game required:

- **`interior_viewer.tscn`** — a single interior CELL's REFRs.
- **`exterior_viewer.tscn`** — a rectangular area of a worldspace's exterior
  cells (terrain + REFRs).
- **`nif_viewer.tscn`** — any single NIF's real SceneNode hierarchy, given
  its MODL-style relative path.
- **`cell_viewer.tscn`** (non-`@tool`, Play-mode) — free-fly interactive
  viewer through the real `GamebryoObjectRegistry` construction path.
- **`free_cam.gd`** — the shared no-clip free-fly camera controller these
  use.

### Native standalone C++ tools (`native/tools/`)

Small CLIs with **no Godot dependency at all** — they link the same
`native/src/` parsers directly, so they're the fastest way to check a real
data question (what does this cell/record/NIF actually contain?) without
booting Godot at all. Existing tools (each has its own top-of-file comment
explaining what it answers):

| Tool | Answers |
|---|---|
| `dump_object` | STAT→NIF→BSA→glTF end-to-end integration check |
| `land_cell_dump` | one cell's real BTXT/ATXT ground-texture references, resolved to paths |
| `land_data_check`, `land_subrecord_dump` | raw LAND subrecord structure/stats |
| `vnml_check` | VNML (authored normal) subrecord presence/decoding |
| `alpha_survey` | NiAlphaProperty/shader-flag survey across NIFs matching a path substring |
| `anim_survey` | NiControllerManager/Sequence content survey, for scoping animation work |
| `light_survey`, `light_nif_correlation` | NiLight block survey / LIGH-vs-authored-light correlation |
| `terrain_census` | worldspace-wide grid/region-size/texture-budget research |

**Compiling a new one-off diagnostic tool**: this is a normal, expected
workflow in this project (used repeatedly to settle real-data questions
during bug investigations) — write a small `.cpp` including whatever
`native/src/` headers you need, and compile directly against the relevant
`.cpp` sources with plain `g++`, no SCons/build-system changes needed:

```bash
cd native
g++ -std=c++17 -O2 -Isrc \
    tools/your_tool.cpp \
    src/esm/esm_file.cpp \
    -lz -o tools/your_tool
```

Add `src/bsa/bsa_archive.cpp` if you touch BSA archives directly. For
anything that loads NIFs, add nifly:

```bash
g++ -std=c++17 -O2 -Isrc -Inifly/include -Inifly/external \
    tools/your_tool.cpp \
    src/bsa/bsa_archive.cpp src/esm/esm_file.cpp src/nif/nif_loader.cpp \
    nifly/src/*.cpp \
    -lz -o tools/your_tool
```

`EsmFile::open()`/`BsaArchive::open()` throw `std::runtime_error` on
structural problems — wrap in try/catch rather than checking a bool return.
Point tools at the real data: `fresh_nv_copy/Data/FalloutNV.esm` and its
BSAs. One-off tools used only for a single investigation don't need to be
committed (`native/tools/*.cpp` already has plenty of "throwaway scratch
tool" precedent, but committing genuinely reusable ones like `land_cell_dump`
is also fine — several already are).

### Test suite (`project/tests/`)

Real, self-checking Godot scenes exercising the actual native classes
against real shipped game data — not mocks. See `project/tests/README.md`
for the full running instructions; summary:

```bash
# One-time after a fresh checkout or adding/renaming a test file:
tools/Godot_v4.7.1-stable_linux.x86_64 --headless --editor --quit

# Run one test:
cd project
../tools/Godot_v4.7.1-stable_linux.x86_64 --headless --path . tests/test_bsa.tscn
```

A passing test prints `  OK   ...` lines and ends with `ALL CHECKS PASSED`,
exit code 0; a failing one prints `  FAIL  ...` lines, `FAILURES: N`, exit
code 1. `test_exterior_cell.tscn` is an interactive viewer, not a pass/fail
test — needs a real (non-headless) instance and manual closing. See that
README for known, pre-existing non-failures (real, out-of-scope issues, not
regressions) before assuming a fresh failure is new.

## Building the GDExtension

```bash
cd native
scons platform=linux target=template_debug api_version=4.7 use_static_cpp=no disable_exceptions=no -j$(nproc)
```

Output: `project/bin/libnv_engine.linux.template_debug.x86_64.so` — builds
directly into place, no manual copy step. See `native/README.md` for why
each flag is needed.

**Rebuild after pulling or making any change under `native/src/`** — a real
gotcha, found the hard way: `project/bin/*.so` is gitignored, so `git pull`
never rebuilds it. A stale `.so` doesn't fail loudly — GDScript call sites
that add a new native method typically guard with
`esm.has_method("new_method")` first (the established defensive pattern for
calling into `EsmReader`), so against a stale binary they just silently
return empty/default data instead of erroring. A landed feature can look
completely missing — inert, not broken — with no error printed anywhere,
until you rebuild. Confirmed directly: PR #38 added
`EsmReader.get_all_item_candidates()`/`get_all_cell_candidates()` for the
Scripting tab's autocomplete; the local `.so` predated that merge by ~11
hours, and the feature silently no-opped until rebuilding fixed it.

**`native/terrain3d` is a separate GDExtension with its own build**, and a
real gotcha: it has its own embedded demo project
(`native/terrain3d/project/`), separate from this repo's real
`project/`. Rebuilding it only updates the demo copy's `.so` — you must
manually copy the result into the real project's addon directory:

```bash
cd native/terrain3d
scons platform=linux target=template_debug -j$(nproc)
cp project/addons/terrain_3d/bin/libterrain.linux.debug.x86_64.so \
   ../../project/addons/terrain_3d/bin/libterrain.linux.debug.x86_64.so
```

(No `api_version=4.7` for Terrain3D — it pins its own, older, nested
`godot-cpp` submodule; see `native/README.md`'s Dependencies section for
why forcing this repo's newer pin onto it fails to compile.)
