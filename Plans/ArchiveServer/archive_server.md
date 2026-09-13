# ArchiveServer

*Clean-slate design for the shared BSA archive layer.*

ArchiveServer is the common byte-source for NifServer, TextureServer, sound loading, and diagnostic
callers. The expensive and thread-sensitive work belongs in native C++; the Godot-facing autoload is
thin lifecycle/configuration glue.

| | |
|---|---|
| **replaces** | the duplicated BSA ordering, reader dictionaries, and `resolve_bytes()` logic in `GamebryoMeshResolver` |
| **native core** | immutable archive catalog plus concurrent positional extraction |
| **Godot surface** | thin `ArchiveServer` autoload wrapper |
| **depends on** | validated game-data directory and the existing `BsaArchive` parser |
| **status** | design sketch; `pread()` and C++ catalog direction settled |

## Goals

- Open the legal FNV `Data/` BSA set once.
- Preserve the current project BSA priority exactly until a better load-order model is deliberately
  verified.
- Resolve one normalized path to one winning archive entry without rescanning every archive.
- Allow concurrent NIF/DDS/WAV reads from the same archive.
- Keep archive lookup and decompression independent of the active scene tree and RenderingServer.
- Expose enough metadata for diagnostics and prefix-discovery callers.
- Return explicit success/failure information rather than treating every empty byte array as equivalent.

ArchiveServer does not interpret ESM records, decode DDS, construct Godot Resources, or attach scene
nodes. TextureServer owns image decoding/upload; NifServer owns NIF parsing/building.

## Path contract

ArchiveServer accepts Data-relative asset paths and normalizes them to lowercase forward-slash form:

```text
meshes\\architecture\\foo.nif  ->  meshes/architecture/foo.nif
TEXTURES\\WALLS\\stone.dds       ->  textures/walls/stone.dds
```

Normalization is only separator/case normalization plus validation. Reject empty paths, absolute paths,
`..` traversal, and `res://`/filesystem paths. Do not silently add an asset-domain prefix: callers must
provide the Data-relative form appropriate to the asset. NifServer strips an optional leading
`meshes/` before its own canonical model identity, then asks ArchiveServer for `meshes/<model>`.

The catalog key is the normalized path. Archive filenames and entry names are not cache identities.
The winning archive is selected once while the immutable catalog is built.

## BSA priority

V1 carries forward the existing project heuristic in `GamebryoMeshResolver._build_bsa_order()`:

1. `Update.bsa`, if present.
2. Non-`Fallout - ` archives in sorted order (the DLC archives).
3. Base archives in this order when present:
   `Fallout - Misc.bsa`, `Fallout - Sound.bsa`, `Fallout - Voices1.bsa`,
   `Fallout - Meshes.bsa`, `Fallout - Textures2.bsa`, `Fallout - Textures.bsa`.
4. Any remaining archives in sorted order.

For duplicate normalized entries, the first archive in this order wins. The catalog must retain the
winning archive name for diagnostics. A future load-order implementation is separate work; this plan
does not pretend the heuristic is a complete mod/load-order simulation.

## Native architecture

### Existing `BsaArchive`

`BsaArchive` already parses one archive and owns a per-archive normalized `path_index_`. Keep that
single-archive API and add the concurrency guarantee below:

- `open()` remains a one-time initialization operation.
- `find()` reads immutable indexes after initialization.
- `read_at()` uses true positional I/O: `pread()` on POSIX and `ReadFile()` with an `OVERLAPPED` offset
  on Windows.
- `extract()` performs all reads positionally, including embedded-name probes and compressed payloads.
- No shared `fseek()`/`fread()` cursor remains in the concurrent path.
- Read errors remain distinguishable from “entry not found.”

The native archive object is read-only after `open()`. A `BsaArchive` instance may therefore serve
concurrent extraction calls. The implementation must not mutate decompression buffers or parser/index
state during extraction.

### `BsaArchiveCatalog`

Add a native catalog (tentative name `BsaArchiveCatalog`) that owns:

- the ordered collection of opened `BsaArchive` instances;
- the immutable BSA priority list;
- a global normalized-path index mapping to `{archive_index, entry_index}`;
- optional archive/entry metadata needed for diagnostics and prefix enumeration.

Catalog construction scans each archive's already-parsed entries in priority order and inserts only the
first occurrence of each normalized path. After construction, the catalog is immutable and safe for
concurrent lookups and extraction. No worker may trigger lazy archive opening or mutate the global map.

The global index is a performance and consistency layer above each archive's existing index; it is not
a second decompression cache and does not retain extracted file bytes.

### Godot-facing wrapper

The native catalog is exposed through a thin Godot `RefCounted` wrapper, tentatively `ArchiveCatalog`.
`ArchiveServer` is the autoloaded GDScript facade that:

- obtains the validated data directory;
- creates and initializes the native catalog before serving requests;
- exposes the project-facing read/list API;
- reports initialization and read failures;
- does not maintain per-worker reader dictionaries or duplicate the global path index.

The final class names may follow the repository’s established `BsaReader` naming once the native API
shape is implemented. The important boundary is native catalog/index/I/O versus thin Godot lifecycle
glue.

## Project-facing API

The exact typed wrapper can be finalized during implementation, but the contract is:

```gdscript
ArchiveServer.read(path: String) -> Dictionary
# {
#   "found": bool,
#   "archive": String,
#   "data": PackedByteArray,
#   "error": String
# }

ArchiveServer.list_files_with_prefix(prefix: String) -> PackedStringArray
ArchiveServer.contains(path: String) -> bool
ArchiveServer.get_stats() -> Dictionary
```

`read()` is callable from worker threads after initialization. It returns a fresh byte buffer; callers
must not mutate shared catalog state because there is none. `contains()` and prefix enumeration are
read-only and use the same normalized catalog. `get_stats()` may be main-thread-only if its counters
are mutable; it is not part of the worker data path.

`read()` must distinguish:

- not found;
- archive unavailable/initialization failure;
- extraction/decompression failure;
- successful zero-length data, if the format permits it.

Existing GDScript consumers can temporarily adapt the explicit result to their current `{bsa, data}`
shape, but new consumers must not infer failure solely from `data.size() == 0`.

## Threading and lifetime

- Catalog initialization happens before NifServer and TextureServer accept work.
- No BSA is opened lazily from a worker.
- The catalog and all archive indexes remain immutable after initialization.
- `read()` performs no scene-tree, RenderingServer, PhysicsServer3D, or TextureServer calls.
- Concurrent calls may read the same archive through positional offsets.
- ArchiveServer remains alive as an autoload for the application lifetime.
- Shutdown marks the catalog unavailable and prevents new reads; it does not block a worker waiting for
  another worker or server.
- If shutdown ordering requires it, the native catalog stays alive until all submitted reads have
  returned, using normal ownership/refcounting rather than a main-thread blocking wait.

## Build and migration order

1. Add native positional-read support and platform-specific error handling.
2. Add unit/standalone tests proving concurrent reads from one archive match serial reads byte-for-byte.
3. Add the immutable C++ global catalog and priority-index tests.
4. Add the thin Godot wrapper and autoload initialization.
5. Verify NIF, DDS, and WAV reads against the current `GamebryoMeshResolver` path.
6. Repoint TextureServer and NifServer to ArchiveServer.
7. Repoint discovery callers such as KF census/prewarm tooling.
8. Remove duplicated BSA reader/order code only after parity tests pass.

The old resolver may coexist during migration. No in-place rewrite of its six construction paths is
required just to ship ArchiveServer.

## Verification gates

- Every BSA in the real `Data/` directory opens or reports a specific initialization failure.
- The global catalog’s priority winner matches the existing resolver for a complete entry census.
- Serial and concurrent extraction return identical bytes for representative and repeated NIF, DDS,
  and WAV paths.
- Embedded-name and compressed-entry extraction are covered explicitly.
- Prefix enumeration is deduplicated using the same winner rule as `read()`.
- Missing paths, malformed archives, decompression failures, and zero-length data are distinguishable.
- No worker test performs lazy archive opening or mutates catalog/index state.
- NifServer and TextureServer show no path-resolution or duplicate-reader regressions after migration.

## Open questions

Settled for V1 (2026-09-12). Each is cheap to revisit; none is load-bearing on the others.

| question | decision |
|---|---|
| Loose files in `Data/` | **Out of scope for V1.** The current resolver is BSA-only; adding loose-file precedence implicitly would change resolution silently. Tracked as follow-up. |
| Native/wrapper class names | Native `BsaArchiveCatalog`, Godot wrapper `ArchiveCatalog`, autoload `ArchiveServer` — follows the existing `BsaReader` convention. |
| `get_stats()` counters | **Main-thread diagnostic snapshot, no atomics.** `read()` touches no counters, keeping the worker data path lock-free. |
| Windows support | The `pread()` / `ReadFile`+`OVERLAPPED` shim is implemented both ways (`native/src/bsa/positional_read.cpp`). The Windows path is **written but unverified** — no Windows host available here. |
| Global index contents | **Compact `{archive_index, entry_index}` integer pairs**, as this document already preferred: unambiguous ownership, no dangling entry references. |

### Still open

- [ ] Loose-file participation and precedence, if it is ever wanted.
- [ ] Verification of the Windows positional-read path on a real Windows host.
