# Native GDExtension

Phase 0 native module. See [phases/0/00-build-scaffolding.md](../phases/0/00-build-scaffolding.md)
for the task this scaffolds.

## Godot binary: use the native build, not the flatpak

**Do not use the flathub `org.godotengine.Godot` flatpak for this project**, despite it
being the system-installed copy. Its bundled `org.freedesktop.Platform//25.08` runtime
ships an older glibc than this host's compiler targets by default — a GDExtension `.so`
built with the host toolchain fails to `dlopen()` inside the flatpak sandbox
(`GLIBC_2.43' not found`). The fix isn't worth the complexity (cross-building inside the
SDK sandbox) when the same exact Godot version is available as a plain native binary.

The native binary lives at `tools/Godot_v4.7.1-stable_linux.x86_64` (not committed —
~140MB; see `.gitignore`). It's the same version (4.7.1) as the flatpak, just packaged
as a standalone Linux executable that links against the host's own glibc, so a
host-compiled `.so` loads into it with no ABI mismatch. This matches the working setup
already used in the sibling `voice-editor` GDExtension project.

If setting this up on a new machine: download `Godot_v4.7.1-stable_linux.x86_64` from
the official Godot releases and place it at `tools/Godot_v4.7.1-stable_linux.x86_64`,
`chmod +x` it. Confirm the version banner reads `4.7.1.stable.official...` (not
`...flathub...`) before relying on it.

## Building

```
cd native
scons platform=linux target=template_debug api_version=4.7 use_static_cpp=no disable_exceptions=no -j$(nproc)
```

- `api_version=4.7` — must be passed explicitly; godot-cpp doesn't yet have a dedicated
  `godot-4.7` branch (branch cadence lags stable releases), so we're on `master`, which
  ships a bundled `extension_api-4-7.json` matching our installed Godot version.
- `use_static_cpp=no` — the Linux default (`use_static_cpp=yes`) statically links
  libstdc++/libgcc, which fails on this host (`cannot find -lstdc++`: no static archive
  installed). Dynamic linking works fine since we're matching the host's own glibc/libstdc++
  now (see above) rather than an older sandboxed one.
- `disable_exceptions=no` — godot-cpp defaults to `-fno-exceptions` (Godot core never
  throws). Our format-parser code (BSA/ESM/NIF) uses `std::runtime_error` for malformed
  data rather than a hand-rolled error-code convention, so exceptions need to stay on.
  This is a per-build-tree flag — changing it forces a full godot-cpp recompile.
- Output: `../project/bin/libnv_engine.linux.template_debug.x86_64.so`.

For a release build, add `target=template_release` (and drop `_debug` expectations in
the `.gdextension` config's referenced path — both debug and release keys are already
listed there).

### Dependencies

- **zlib** — used by the BSA reader for per-file decompression. Linked via `-lz`
  against the system library (`zlib.h`/`libz.so` — confirmed present via
  `pkg-config zlib`). No vendoring needed.
- **nifly** — used by the NIF mesh parser (task 0.3), vendored as a git submodule at
  `native/nifly/`. Built directly into the extension (its `src/*.cpp` globbed
  alongside ours) rather than as a separate static library — it has no dependencies
  beyond its own bundled headers. Requires C++17, already the default in godot-cpp's
  build flags.

  **It is patched at build time.** The submodule is pinned to upstream, so local
  fixes cannot be committed into the checkout; they live in `native/nifly_patches/`
  and `SConstruct` applies them before the glob. `git status` therefore reports
  `native/nifly (modified content)` on any built tree — that is expected, and is the
  patch being present. Do not check it out or force-update it away; the next build
  re-applies it either way. See
  [`nifly_patches/README.md`](nifly_patches/README.md).
- **Terrain3D** — third-party terrain GDExtension addon (see
  [phases/2/13-terrain3d-integration.md](../phases/2/13-terrain3d-integration.md)),
  vendored as a git submodule at `native/terrain3d/`, pinned to the `v1.0.2-stable`
  release tag (not `main` — main is 671+ commits past the last stable tag). It's a
  **separate GDExtension from our own `nv_engine`**, built independently:

  ```
  cd native/terrain3d
  scons platform=linux target=template_debug -j$(nproc)
  ```

  No `api_version=4.7` here, deliberately — Terrain3D's own bundled `godot-cpp`
  submodule (a much older pin than ours, matching what its source was actually
  written against) is checked out as-is rather than repointed at our own
  `native/godot-cpp` commit. Forcing our newer pin onto Terrain3D 1.0.2's source
  fails to compile (`Math_PI`/`std::hash` no longer implicitly available — a real
  header-surface change between the two `godot-cpp` versions). This isn't a problem:
  GDExtension's whole design point is ABI stability across minor engine versions, so
  a `.so` built against an older `godot-cpp`/API snapshot loads fine into the newer
  4.7.1 binary both extensions actually run in — confirmed via a real headless
  editor pass (`terrain.gdextension`'s own `compatibility_minimum = 4.4` states this
  explicitly). Output: `project/addons/terrain_3d/bin/libterrain.linux.debug.x86_64.so`
  (gitignored, same never-commit-compiled-binaries convention as `project/bin/`,
  rebuild after any fresh checkout). The GDScript-side addon files themselves (not
  the compiled binary) are copied — not symlinked — into `project/addons/terrain_3d/`
  from `native/terrain3d/project/addons/terrain_3d/`, matching how the upstream
  project's own installation instructions describe adding it to an existing project;
  re-copy after updating the submodule to a newer tag. Enabled via
  `project/project.godot`'s `[editor_plugins]` section.

## Verifying the extension loads

The `project/` directory is a minimal Godot project whose sole scene (`test_scene.tscn`)
instantiates the native `NVPing` class and calls its `ping()` method, printing the
result and quitting. This is the smoke test for "did the build/load round trip work,"
not a real feature.

```
# One-time: headless editor pass to generate project/.godot/ cache (extension
# discovery requires this before extension classes resolve — a fresh checkout or a
# deleted .godot/ needs this step first, otherwise class lookups like `NVPing` in
# GDScript/scenes fail with "Could not find base class").
tools/Godot_v4.7.1-stable_linux.x86_64 --headless --editor --quit --path project

# Actual test run:
tools/Godot_v4.7.1-stable_linux.x86_64 --headless --path project
```

Expected output: `NVPing.ping() -> nv-engine-native-ok`, exit code 0.

Note: the `--editor --quit` pass currently ends in a core dump on this system during
headless editor shutdown — harmless (the `.godot/` cache is written before the crash,
and it's not related to our extension), but don't mistake the nonzero/crash exit from
*that* invocation for a real failure. Only the second command's exit code/output
matters for verification.

## Layout

```
native/
  godot-cpp/    — vendored as a git submodule (master branch, includes 4.7 API json)
  nifly/        — vendored as a git submodule, NIF mesh library used by task 0.3
                  (patched at build time from nifly_patches/ — see Dependencies)
  nifly_patches/— local fixes applied to the nifly submodule by SConstruct
  terrain3d/    — vendored as a git submodule (v1.0.2-stable), separate GDExtension
                  addon — own nested godot-cpp submodule, own SConstruct, see above
  src/
    common/     — shared byte-reader/endian helpers (little-endian throughout)
    bsa/        — task 0.1
    esm/        — task 0.2
    nif/        — task 0.3 (thin wrapper over nifly/ + a generic glTF exporter)
    dds/        — task 0.4
    register_types.cpp/h, ping.h/cpp — extension entry point + sanity-check class
  SConstruct
project/
  bin/                    — build output + nv_engine.gdextension manifest
  addons/terrain_3d/      — Terrain3D addon files (copied from terrain3d/project/,
                             bin/ gitignored — see Dependencies above)
  test_scene.tscn/.gd     — the ping smoke test
tools/
  Godot_v4.7.1-stable_linux.x86_64  — native Godot binary (gitignored, see above)
```
