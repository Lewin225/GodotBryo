# 0.0 — GDExtension Build Scaffolding

Parent: [Phase 0](README.md)

## Goal

A working build pipeline that produces a native GDExtension shared library Godot can
load, before any real parsing logic exists. Everything downstream in Phase 0 is native
C++ code — get the plumbing right first so each subsequent task is "add a class,"
not "fight the build system."

## Why native code, not GDScript

BSA decompression, NIF binary parsing, and DDS decoding are byte-level, performance-
sensitive, and benefit from existing C/C++ libraries (`nifly`, zlib/lz4, etc.).
GDExtension lets this code live outside Godot's own source tree and still expose
classes/resources directly to the engine.

## Steps

1. Target is fixed: **Godot 4.7.1**. Use the native standalone Linux binary
   (`tools/Godot_v4.7.1-stable_linux.x86_64`), **not** the system-installed flathub
   flatpak (`org.godotengine.Godot`) — despite being the "system installed" one, its
   bundled runtime ships an older glibc than this host's compiler targets, and a
   host-built GDExtension `.so` fails to load inside it (`GLIBC_2.43' not found`).
   The native binary is the same exact version, just not sandboxed, so a host-compiled
   `.so` loads with no ABI mismatch. See [native/README.md](../../native/README.md)
   for the full story and where to source the binary on a fresh machine.
2. Vendor `godot-cpp` (the official C++ bindings for GDExtension) as a submodule. No
   dedicated `godot-4.7` branch exists yet (branch cadence lags stable releases) — use
   `master`, which already ships a bundled `extension_api-4-7.json` matching our
   installed version. Pass `api_version=4.7` explicitly at build time.
3. Choose a build system: SCons (matches Godot's own build, best-documented for
   GDExtension) or CMake (more familiar tooling, community templates exist). Pick one
   and don't mix.
4. Scaffold a minimal extension:
   - One trivial exposed class (e.g. a `Node` subclass with a ping method) to prove
     the round trip: C++ compiles → `.gdextension` file registers it → Godot editor
     sees the class → calling a method from a test scene returns the expected value.
   - `.gdextension` config file with correct entry symbol and per-platform library
     paths.
5. Set up a project-local Godot project (`project/` or similar) whose sole purpose
   for now is loading the extension and running the Phase 0 sanity checks.
6. Decide directory layout up front, e.g.:
   ```
   native/
     bsa/
     esm/
     nif/
     dds/
     common/        (shared byte-reader/endian helpers)
   project/          (Godot project that loads the extension)
   tools/            (Phase 0.5 CLI dump tool, if built as a separate binary rather
                       than in-editor)
   ```
7. Wire up a single build command (`scons` target or `cmake --build`) that produces
   the library for your primary dev platform. Multi-platform builds are not required
   yet — cross-platform packaging belongs later, once there's something worth
   packaging.

## Deliverables

- `native/` directory with working build config.
- A Godot project that loads the extension and confirms it's live (e.g. prints a
  version string or responds to a ping call) on editor start.
- A one-line build command documented in a `native/README.md`.

## Acceptance criteria

- [ ] Clean checkout + one documented command builds the extension with no manual
      steps.
- [ ] Godot editor opens the test project without GDExtension load errors.
- [ ] A GDScript or editor script call into the native ping class returns correctly.

## Notes / risks

- Keep the endian/byte-reader utility (little-endian throughout for Bethesda formats)
  in `native/common/` from the start — every subsequent parser (BSA, ESM, NIF) needs
  it, and duplicating it per-module now creates cleanup work later.
- **Use the native binary, not the flatpak** (see step 1) — this was discovered the
  hard way: the flatpak loads the project fine but rejects the GDExtension `.so` at
  `dlopen()` time due to a glibc version mismatch with the host toolchain. No sandbox
  filesystem permissions were actually the issue; don't waste time on
  `flatpak override --filesystem=...` for this.
- **First run needs a headless editor pass.** A fresh checkout (or any time
  `project/.godot/` is deleted) needs one `--headless --editor --quit` run before
  GDExtension-registered classes resolve in scenes/scripts — otherwise class lookups
  fail with "Could not find base class." On this system that pass currently ends in a
  core dump during shutdown; harmless; the cache is written before it crashes. Only
  the subsequent real run's exit code matters.
- Don't reach for Godot's `FileAccess` inside the low-level parsers if it adds
  friction — plain `std::ifstream`/mmap is fine for Phase 0 standalone tools; only
  the final integration layer needs to speak Godot resource types.
