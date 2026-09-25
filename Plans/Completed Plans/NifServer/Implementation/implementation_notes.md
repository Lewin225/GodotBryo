# Server Stack: Implementation Notes

What Stages A–D of [`server_stack_build_order.md`](../../server_stack_build_order.md) actually built,
and the things that were only discovered by building it.

Companion: [`outstanding_issues.md`](outstanding_issues.md).

---

## Index

| # | Area |
|---|---|
| [1](#1-what-exists) | What exists |
| [2](#2-api-surface) | API surface |
| [3](#3-implementation-decisions) | Implementation decisions |
| [4](#4-gotchas-found-by-building) | Gotchas found by building |
| [5](#5-measured-behaviour) | Measured behaviour |

---

## 1. What exists

| stage | files | gate |
|---|---|---|
| **A** `pread` | `native/src/bsa/positional_read.{h,cpp}`, patched `bsa_archive.{h,cpp}` | `tests/servers/test_bsa_concurrent` ✅ |
| **B** ArchiveServer | `native/src/bsa/bsa_catalog.{h,cpp}`, `archive_catalog_gd.{h,cpp}`, `project/GodotBryo/Servers/ArchiveServer/archive_server.gd` | `tests/servers/test_archive_server` ✅ |
| **C** TextureServer | `project/GodotBryo/Servers/TextureServer/texture_server.gd` | `tests/servers/test_texture_server` ✅ |
| **D** NifSource | `native/src/nif/nif_source.{h,cpp}`, `nif_source_gd.{h,cpp}` | **not written yet** |

Also `tests/servers/test_texture_corpus_sweep` — a measurement, not a gate.

`ArchiveServer` and `TextureServer` are registered autoloads, in that order, ahead of `EsmServer`.
The legacy `NifReader` / `nif_loader.cpp` and `mesh_resolver.gd` are untouched and still serve their
existing callers.

---

## 2. API surface

### ArchiveServer (autoload)

```gdscript
read(path) -> {found: bool, archive: String, data: PackedByteArray, error: String}
contains(path) -> bool
winning_archive(path) -> String     # index-only, no extraction
list_files_with_prefix(prefix) -> PackedStringArray
is_ready() -> bool  ·  get_init_error() -> String  ·  get_stats() -> Dictionary
```

`read()`, `contains()`, `winning_archive()` and `list_files_with_prefix()` are safe from worker
threads after initialisation. Everything else is main-thread.

### TextureServer (autoload)

```gdscript
warm(path, alpha_safe := false)      ·  request(path, alpha_safe := false) -> ImageTexture
request(path, alpha_safe := false) -> ImageTexture         # coroutine
warm(path, alpha_safe := false) -> void                    # any thread
is_finished(path, alpha_safe := false) -> bool             # success OR failure
purge(path, alpha_safe := false)  ·  purge_all()
cache_key(path, alpha_safe) -> String    # static
get_stats()  ·  reset_stats()
```

### NifSource (native `RefCounted`)

```gdscript
load(bytes: PackedByteArray) -> bool  ·  get_last_error() -> String
get_version() -> String  ·  get_block_count() -> int
get_nodes() -> Array               # one per NiAVObject
get_object_palettes() -> Array     # NiDefaultAVObjectPalette entries
get_sequences() -> Array           # NiControllerSequence, targets resolved, with curves
get_collision_shapes() -> Array  ·  get_collision_bodies() -> Array
```

Each `get_nodes()` entry: `name`, `block_type`, `parent_index`, `block_index`, `transform`,
`collision_type`, `collision_block_index`, `texture_slots` (6 when a set exists),
`texture_set_block_index`, `shader_type`, `property_block_indices`, `property_types`, `extra_data`,
and when the node is geometry: `positions`, `normals`, `uvs`, `colors`, `indices`, `skin`, `morphs`.

Each `get_sequences()` controlled block carries an `interpolator` dictionary: `present`, `block_type`,
`kind` (`transform` / `float` / `bool` / `point3` / `blend` / `unsupported`), `resampled`,
`rotation_from_euler`, the interpolator's own static value, and `translation_keys` (meters),
`rotation_keys` (`Quaternion`, XYZW), `scale_keys`, `float_keys`, `point3_keys`.

---

## 3. Implementation decisions

| decision | reason |
|---|---|
| **NifSource takes bytes, not a path** | Keeps the native parser free of any GDScript/autoload reference. `ArchiveServer.read()` and a pure native parse are each worker-safe, so a resolver can do both off-thread. |
| **Zero-copy parse** | A `streambuf` reads straight out of the caller's `PackedByteArray`. The obvious route (`vector` → `string` → `istringstream`) copied every NIF three times before nifly saw a byte. `seekoff`/`seekpos` are real implementations because nifly seeks while parsing. |
| **Positions in meters at the source** | Matches `units.h`: `/70` for Gamebryo, `/10` for Havok. Verified by cross-check — `barracks01` render mesh 12.69 m vs its collision mesh 12.68 m, two different unit systems agreeing to 1 cm. |
| **Block indices exposed, never resolved** | Palette aliases, shared property blocks and texture sets all report a block index. Precedence and fan-out are the server's policy, not the reader's. |
| **`texture_slots` empty means no texture set** | Gated on a real `TextureSetRef()`. Populating six empty strings for every shape made "has a set" meaningless and diluted the occupancy figures. |
| **New native code lives in `src/nif/` and `src/bsa/`** | `SConstruct` globs those directories; a new directory would have required a build-system change. |
| **TextureServer caches no `Image`** | Only the `ImageTexture` is kept. An `Image` cache alongside it would hold a second CPU-side copy of a 4.26 GB corpus for a buffer nothing reads back. |
| **Transform curves are bound, property curves are not** | An `AnimationPlayer` is emitted only for sequences whose targets are nodes in the same file, and only from `kind == "transform"` links. The split mirrors the skeleton rule: a self-contained clip binds, a clip addressing a rig composed elsewhere is named in `nif_unbound_sequences` for the caller to retarget. |
| **Collision hangs off its owning node** | One body per distinct `owning_node_index`, parented under that node (or its `BoneAttachment3D`), never in bulk at the root. Shape data is in the owner's local space, so the owner's own transform chain places it — and once that node is animated, its collision travels with it. An animated owner gets an `AnimatableBody3D`; a `StaticBody3D` that moves pushes nothing. |
| **B-splines are sampled, and say so** | Cubic control points have no keyframe equivalent, so `NiBSpline*TransformInterpolator` is evaluated adaptively (1 cm / 0.2° / 0.2% tolerances) and the result is flagged `resampled`. The evaluator is duplicated rather than shared with `nif_loader.cpp`, which stays untouched. |
| **A pure decode plus a cached upload is not a cache** | `TextureServer.decode()` is pure by design and consults nothing; only `upload()` reads the cache. Pairing them, as NifServer did, re-read and re-decoded the DDS on every call and deduplicated only the GPU upload -- 157 ms of a 174 ms 60-model build, at a 3.4x texture reuse factor. Both are now private; `warm()` and `request()` are the whole external surface, which is what the server was specified with. `build()` warms every slot as a batch, then awaits them, so it is a coroutine. Measured after: 173.7 ms -> 21.4 ms warm. |
| **No atomics anywhere** | Every cache, counter and queue is main-thread-owned. `_decode()` and `ArchiveServer.read()` are pure, so the worker data path touches no shared mutable state. |

---

## 4. Gotchas found by building

Each cost real time; each is cheap to avoid once known.

| gotcha | detail |
|---|---|
| **Scene-tree access is forbidden on workers** | `_decode()` called `get_tree().root.has_node("ArchiveServer")` per call. Godot rejects it off-thread. The reference must be resolved once in `_ready()`. Being documented "worker-safe" means nothing until a worker actually calls it. |
| **Autoload order is a silent dependency** | TextureServer resolves ArchiveServer in `_ready()`, so it must be declared after it in `project.godot`. Reversed, every decode returns null. |
| **`class_name` needs an import pass** | New global classes are unresolvable to `--script` runs until `--headless --editor --quit-after 40` regenerates the class cache. |
| **`max()`/`min()` return `Variant`** | The project treats inferred-Variant as an error. Use `maxi`/`mini`/`maxf`. |
| **`%` is illegal in Godot node names** | It cannot be the escape character for the name mapping — Godot strips it. `_` works, escaping itself first as `_5F`. |
| **`Matrix4` is a flat `float[16]`** | Not `[r][c]`. Translation sits at indices 3, 7, 11 — the only entries needing a unit conversion. |
| **`str = buf.get()` truncates** | The root of the nifly palette bug. Any `char*` → `std::string` assignment stops at an embedded NUL. |
| **Array literals inside hot loops** | A `for k in ["a","b",...]` inside a per-reference loop stalled a 25k-file sweep past 900 s. The same sweep without it runs in 6.9 s. |
| **B-spline interpolators are not `NiTransformInterpolator` subclasses** | In nifly they descend from `NiBSplineInterpolator`, so a `dynamic_cast` chain that tests the ordinary transform type first silently drops every compressed clip. Test for the spline form first. |
| **`XYZ_ROTATION_KEY` is on the data block, not the key** | Three independent per-axis float curves with their own key times, not quaternion keys. They have to be composed onto the union of those times before anything can play them. Both of the vault door's sequences are this form. |
| **`user://` is invisible to native code** | Test fixtures written there failed at `fopen` rather than at the structural check they were meant to exercise, so two tests passed for the wrong reason. Use `OS.get_user_data_dir()`. |

---

## 5. Measured behaviour

| | |
|---|---:|
| archives indexed | 21, in 175 ms |
| catalog entries (priority winners) | 181,642 |
| duplicate paths shadowed by DLC overrides | 535 total; 204 `.nif`, 453 `.nif`+`.kf` |
| NIF/KF files parsed by NifSource | 25,307, **0 failures**, 6.9 s |
| `NiAVObject` blocks | 140,475 across **exactly 18** types |
| textures decoded + uploaded | 26,840 in 6.6 s (**~4,000/s**), 0 failures |
| whole texture corpus resident | 4.88 GB peak process memory |
| concurrent extraction | 8 threads × 40 entries byte-identical to serial |

Counts from NifSource run slightly below the offline research figures because ArchiveServer returns
**priority winners only**; the difference is exactly the duplicate count above.
