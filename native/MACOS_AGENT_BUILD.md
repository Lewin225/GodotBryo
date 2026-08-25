# macOS local build guide for agents

Use this guide when working from a macOS checkout of this repository. It
builds the two native GDExtensions the Godot project needs locally; neither
their framework outputs nor Fallout: New Vegas assets belong in Git.

## Preconditions

1. Install **Xcode Command Line Tools** and a Python 3 environment with
   SCons available.

   ```bash
   xcode-select --install
   python3 -m pip install --user scons
   ```

2. Download the native macOS **Godot 4.7.1** editor from Godot's official
   releases. Do not use a different engine version for this project.

3. Place a legally-owned Fallout: New Vegas `Data` directory at the
   checkout-local path `fresh_nv_copy/Data/`. It is gitignored and must never
   be copied into source control. To use another installation location, set
   `GODOTBRYO_DATA_DIR` (or the legacy alias `FNV_DATA_DIR`) to the directory
   containing `FalloutNV.esm` before launching Godot. The override is
   authoritative and deliberately fails with an error if that file is absent.

4. Initialise the repository submodules before compiling. In particular,
   `native/godot-cpp`, `native/nifly`, and `native/terrain3d` are build
   dependencies.

## Build `nv_engine`

From the repository root:

```bash
cd native
scons platform=macos target=template_debug api_version=4.7 use_static_cpp=no disable_exceptions=no -j$(sysctl -n hw.ncpu)
```

The build must create this local framework in the real Godot project:

```text
project/bin/libnv_engine.macos.template_debug.framework
```

`project/bin/nv_engine.gdextension` already selects that framework through
its `macos.debug` entry. The matching release command changes only
`target=template_release`, producing the framework named by `macos.release`.

Build natively for the Mac being used (Apple Silicon or Intel). Universal
framework packaging is not established by this guide and must not be claimed
as supported without an explicit verified build.

## Build and install Terrain3D

Terrain3D is a separate GDExtension with its own nested build and demo
project. Building it does **not** automatically update this repository's
Godot project.

```bash
cd native/terrain3d
scons platform=macos target=template_debug -j$(sysctl -n hw.ncpu)
ditto project/addons/terrain_3d/bin/libterrain.macos.debug.framework ../../project/addons/terrain_3d/bin/libterrain.macos.debug.framework
```

The final copy step is required: Godot loads Terrain3D from the real project
path below, not from Terrain3D's embedded demo project.

```text
project/addons/terrain_3d/bin/libterrain.macos.debug.framework
```

The addon manifest already contains the `macos.debug` framework path.

## Verify before working

From the repository root, run a headless editor discovery pass using the
macOS Godot binary, then run an appropriate test from `project/`:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --editor --quit --path project
cd project
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . tests/test_bsa.tscn
```

The expected passing test footer is `ALL CHECKS PASSED`. The existing tests
resolve game data through `../fresh_nv_copy/Data/`, relative to `project/`.

## Git boundary

Do not add generated frameworks or game data. The repository intentionally
ignores:

- `project/bin/*.framework` for `nv_engine`;
- `project/addons/terrain_3d/bin/` for Terrain3D output;
- `fresh_nv_copy/` for the original game data.

Commit source, `.gdextension` manifests, tests, and documentation only.
