# NIF Server

*Clean-slate design.*

Not a migration of `mesh_resolver.gd` — a from-scratch spec for what the job looks like with no
breaking-change constraint: one function, one flag, redesigned threading and caching.

| | |
|---|---|
| **built standalone** | migrated in later — not an in-place edit of `mesh_resolver.gd`'s 6 construction paths |
| **companions** | [Shared Texture Server](texture_server.md) · [NifServer Build Order](nif_server_build_order.md) · Mesh Resolver Refactor (pin-down) |
| **status** | design sketch, open to changes |

---

## The job

Given a NIF path, return an accurate node tree. One optional flag strips dynamic behaviour and
flattens the geometry — and skips the parsing that flag makes unnecessary, not just the node
construction.

`request()` is the external entry point. `_resolve()`/`_build()` are its internal two-stage
implementation — not called directly by anything outside NifServer.

| function | visibility | params | returns | thread |
|---|---|---|---|---|
| `request()` | **external** | `nif_path: String`<br>`flatten_static: bool = false` | `Node3D` *(orphaned, unparented)* | coroutine — await from the main thread |
| `_resolve()` | internal | `nif_path: String`<br>`flatten_static: bool = false` | `NifResolveResult` | worker-safe |
| `_build()` | internal | `result: NifResolveResult` | `Node3D` *(orphaned, unparented)* | main-thread only |

**Ownership contract:** neither `_build()` nor `request()` touches a scene tree — NifServer doesn't
know if the caller wants the result parented immediately, cached unparented for later, or discarded.
Returning a node transfers no implicit ownership; the caller must either parent it
(`parent.call_deferred("add_child", node)`) or free it. Worth stating explicitly wherever `request()`
is documented, so callers don't assume NifServer handles attachment.

---

## `_build()`'s output is a conformant Godot object, not raw NIF orientation

Part of "accurate conversion of NIF to Godot": the returned tree is already Y-up and facing Godot's
forward, not Bethesda's. No consumer applies an axis conversion after calling
`request()`/`_build()` — if it needs one, that's a NifServer bug, not a caller responsibility.

Confirmed via `mesh_resolver.gd`: today, nothing converts axes at the NIF-content level at all — the
only correction anywhere is `refr_root_basis()` (a fixed -90° X rotation), applied once at the
*placement* layer, either for free via RefrRoot parenting (CellLoader/CellStreamBuilder/WorldStreamer)
or explicitly via `world_transform_no_parent()` for parentless placements. A NIF's own geometry is
loaded as-authored. Baking the conversion into NifServer's own root transform instead means every
future caller — especially non-REFR previews, which have no RefrRoot to inherit the fix from — gets a
correctly-oriented object with zero placement math, rather than needing to know the axis convention
exists at all (see `esm_reference_physicaliser.gd`'s own hand-reimplemented copy of this exact fix,
found during review — precisely the class of bug this removes).

> **Migration is per-caller, not a flag day.** NifServer and `GamebryoMeshResolver` coexist during the
> transition — existing RefrRoot-based placement (CellLoader/CellStreamBuilder/WorldStreamer) and the
> physicaliser's own `world_transform_no_parent()`/`refr_transform()` calls are untouched and keep
> working exactly as today until each one individually repoints to NifServer — at which point that
> caller drops its own now-redundant conversion step. No coordinated change across the existing
> streaming systems is required to ship NifServer v1 with this built in.

**The transform is a single -90° X rotation** — `Basis(Vector3.RIGHT, deg_to_rad(-90.0))`, the matrix
`(x, y, z) → (x, z, -y)`, determinant `+1`. It covers the up-axis correction and forward-facing
alignment together: Bethesda `+X` (right) stays `+X`, `+Z` (up) becomes `+Y`, and `+Y` (north/forward)
becomes `-Z`, which is `Vector3.FORWARD`. Forward-facing is not a separate degree of freedom — fixing
right and up in a right-handed basis determines the third axis, leaving no yaw component to add.

> **Established from:** `phases/0/04-dds-texture-import.md:120-127`, which names the remap directly
> ("rotated -90° about X, which maps `(x, y, z) → (x, z, -y)` — the standard axis remap") and calls for
> it to become "a first-class, permanent part of the NIF-to-Godot pipeline rather than a one-off in a
> test script". `native/src/nif/units.h` confirms the native layer applies scale only ("Only applies to
> positions/vertex coordinates. Rotation is unitless"), so geometry arrives in Bethesda orientation and
> is converted exactly once. All 20 conversion sites in the project apply `rotation_degrees.x = -90` and
> nothing else, with no yaw anywhere — `nif_viewer.gd:131` included, a bare NIF preview with no REFR,
> which is the non-REFR case this section exists to serve.

---

## Two stages, split where this project has already confirmed it must be

**Worker thread — `_resolve()`**
- NIF / BSA byte parsing
- cheap block-table classification pass — skin/controller presence, and every referenced texture path
- fires `TextureServer.warm()` for each, **before** geometry conversion starts
- skin, controller and collision data extraction
- touches raw data only — **never** ArrayMesh, ImageTexture, Material, Shape3D, decoded texture bytes,
  or any Node (texture decode is [TextureServer](texture_server.md)'s job, not this class's)

→

**Main thread — `_build()`**
- ArrayMesh / Shape3D / StandardMaterial3D construction — assigns an already-uploaded `ImageTexture`
  from [TextureServer](texture_server.md), doesn't call `create_from_image()` itself (that upload
  already happened, on TextureServer's own budgeted queue, likely before `_build()` even runs)
- Node3D / Skeleton3D / MeshInstance3D / CollisionShape3D — orphaned subtree, not yet parented
- caller then does the actual attach: `call_deferred("add_child", node)`

`mesh_resolver.gd`'s own top-of-file comment documents a real, repeatable crash in this project
(RID-table corruption — "Attempting to initialize the wrong RID"):
`ArrayMesh`/`ImageTexture`/`StandardMaterial3D`/`Shape3D` construction all issue real
RenderingServer/PhysicsServer3D calls under the hood. With the Separate Rendering Thread model off,
Godot's `RID_Owner<T>` locking is compiled out entirely off the main thread — and Godot's own current
docs say Separate mode "has several known bugs" and advise against GPU-touching calls off-thread
regardless. Any Node built on those Resources (MeshInstance3D, Skeleton3D, CollisionShape3D) inherits
the same constraint. `_resolve()` stops at plain data — and a texture-decode *request*, not a decode —
for exactly this reason; `_build()` is where every RS/PS3D-backed object gets constructed, main-thread
only.

> The remaining `_build()` cost (ArrayMesh/Shape3D/Material construction, Node instancing) is the
> RS/PS3D call itself and is not reducible further — `_resolve()` already extracts all data prep
> (vertex/index/weight arrays, shape parameters) as plain data first. `builds_per_frame_budget` bounds
> this cost per frame; there is no additional offloading available.

`GamebryoResolverPool`/`GamebryoResolveContext` run a pool of private per-worker raw-resolve contexts
(BSA readers, decoded-Image cache — zero RS calls), merged into one single main-thread resolver
instance that owns all GPU-backed construction.

> NifServer needs no Context-equivalent: patch `BsaArchive` to use a true positional read (`pread()` on
> Linux/macOS, `ReadFile()` + an `OVERLAPPED` offset on Windows) instead of shared-cursor
> `fseek()`+`fread()` (`bsa_archive.cpp:175-180`), making concurrent `read_at()` calls on one shared
> instance safe by construction. In scope as a native prerequisite for the NifServer work; also removes
> the same need from [TextureServer](texture_server.md)'s `decode()`, since DDS textures come from the
> same BSA files.

> **Hard rule, shared with TextureServer:** `_resolve()` must never batch through
> `WorkerThreadPool.add_group_task()` at its default `tasks_needed = -1` — that claims every thread in
> the one pool both servers share for the group task's full duration, and `_build()` cannot proceed
> without a real uploaded texture (no lazy reference), so TextureServer's decode/upload work being
> unable to run is a hang, not a stall. Citations in
> [Shared Texture Server](texture_server.md)'s "Hard rule" section.

---

## Textures warm before geometry conversion even starts

Per `nifly` (the vendored NIF library, `native/nifly/`): texture paths live in their own small block,
`BSShaderTextureSet` — a plain array of up to 13 strings, attached to a shape's shader property. It's
structurally separate from that shape's geometry (vertex/normal/UV/triangle arrays), and today's own
C++ loader (`nif_loader.cpp`) already reads it with a single cheap call per shape,
`GetTextureSlot(shape, tex, slot)` — no vertex data touched.

So the classification pass that already walks the block table for skin/controller presence can harvest
every shape's texture paths — all 6 `BSShaderTextureSet` slots this game's NIF version actually has
(`Shaders.cpp:365-373`: 13 slots is Skyrim SE only; FNV's File 20.2.0.7/User ≥11 gets 6), read
unconditionally on whether the slot string is non-empty, not gated behind a shader flag first — an
occupied slot is the fact, nothing else needs to agree first. Fires `TextureServer.warm()` for each in
the same cheap walk, before any of the comparatively expensive vertex/UV/triangle/skin/controller
conversion. That overlaps texture decode+upload latency with the rest of `_resolve()`'s own work
instead of paying for it serially once `_build()` gets there — free lookahead, for the cost this
project was already going to pay to classify the file.

| slot | convention | currently read? |
|---|---|---|
| `0` | diffuse | yes |
| `1` | normal + gloss (alpha) | yes |
| `2` | glow / emissive | yes |
| `3` | height / parallax | **no** |
| `4` | environment map | **no** |
| `5` | environment mask | **no** |

> Slots 3-5 going unread today is a real rendering gap independent of this redesign — `nifly` already
> exposes `SLSF1_ENVIRONMENT_MAPPING`/`SLSF1_PARALLAX`/`GetEnvironmentMapScale()`
> (`Shaders.hpp:57,61,526`), so some real FNV assets (chrome, glass, wet/metal surfaces) are authored
> with reflective materials this project currently never loads or renders. NifServer's `_resolve()`
> reads all 6 slots.

> Multiple `_resolve()` calls can be in flight on different `WorkerThreadPool` tasks at once, so
> `warm()` cannot mutate `TextureServer`'s pending-queue state directly from inside `_resolve()`.
> `warm()` marshals its own enqueue through `call_deferred`, the same mechanism used for the
> `add_child` hand-off, making it safe to call from any thread.

---

## Async facade, not a core-contract change

GDScript's `await` only works on a signal or a call to another coroutine — there's no built-in
Promise/Future. `_resolve()` is the `WorkerThreadPool` task body; `_build()` stays main-thread (see
above) and runs once the task signals completion — the await contract wraps that hand-off, it doesn't
change what runs where.

```
# request()'s implementation
queues a WorkerThreadPool task running ONLY _resolve() (raw-safe)
task emits a completion signal via call_deferred with the NifResolveResult
request() awaits that signal, then calls _build() itself, on the main thread
NOT WorkerThreadPool.wait_for_task_completion() — blocking, and hangs
under some timing (godot#84936)

# caller:
var node = await NifServer.request(nif_path)
```

---

## KF animation

A `.kf` file is a NIF whose blocks are `NiControllerSequence` data instead of geometry — same
`load_nif()` path, different content. Tracks return with bare authored target names as their paths
(`NodePath("Bip01")`, `NodePath("##VisCtrl")`); binding to a real target is entirely caller-side.

| function | visibility | params | returns | thread |
|---|---|---|---|---|
| `request_kf()` | **external** | `kf_path: String` | `Animation` | worker-safe — `Animation` is not RS-backed |
| `request_retargeted_kf()` | external, **stub** | `kf_path: String`<br>`skeleton_path: NodePath` | `Animation` | not implemented |

> `request_retargeted_kf()` is `request_kf()` plus a rename loop
> (`track_set_path(i, NodePath(str(skeleton_path) + ":" + str(path.get_name(0))))` per track) — cheap
> enough that it may not need threading assistance at all. Only implement it if profiling shows the
> rename loop is expensive enough on the main thread to justify it.

---

## Self-contained: owns its own budget and perf surface

Pacing and queue both live inside `NifServer`, not in whatever calls `request()` — same shape as
[Shared Texture Server](texture_server.md)'s upload budget.

| config var | default | meaning |
|---|---|---|
| `builds_per_frame_budget` | `12` | max `_build()` calls drained per frame |
| `num_workers` | `-1` | admission cap on concurrent `_resolve()` tasks, not a thread count; `-1` = `max(2, OS.get_processor_count() - 1)`, same convention as `GamebryoResolverPool._init()` |

| function | returns | purpose |
|---|---|---|
| `get_stats()` | `Dictionary` | `resolve_cache_hits/misses`, `pending_resolve_count`, `pending_build_count`, `builds_this_frame`, `resident_nif_count` |
| `reset_stats()` | `void` | zeroes the counters above |

---

## What the flag actually does

Not a post-hoc merge on the output tree. `_resolve()` always enumerates the block table first — cheap —
before deciding whether the expensive per-block decode (skin weights, keyframe curves, per-node
transform tracking) is worth doing at all.

| `flatten_static` | file has skin / controllers | behaviour |
|---|---|---|
| `false` | — | full honest tree, every stage decoded |
| `true` | no | **fast path** — skin/controller decode skipped, geometry pooled into merged world-space buffers |
| `true` | yes | flag is **ignored** — content decides, not the caller's guess |

---

## One cache, not three

**Today**
- submesh mesh cache, keyed `model_path#submesh`
- separate skinned-mesh cache
- separate disk KF animation cache
- three identities for the same source NIF

**Rebuild**
- one cache, key `(nif_path, flatten_static)`
- `NifResolveResult` holds only Resources + plain data — safe to share across every placement of that NIF
- disk cache = serialized result under the same key + a content hash for invalidation
- `instantiate()` turns one shared result into N independent node trees

---

## Composed on top, not inside

Everything that isn't "parse one NIF" becomes a caller of these two functions instead of a mode inside
them:

- humanoid multi-file stitching
- equipment / armor-slot interpretation
- rigid-body mass + physics policy
- XEMI tint (REFR-level, not NIF content)
- distant-tile / `_lod.nif` crossover policy

**Texture decode/cache is a dependency, not a caller.** `terrain3d_bridge.gd` already calls
`load_texture()` directly for ground/normal textures with no NIF involved — it is the project's one
shared DDS-decode-and-cache entry point, not a NIF-material detail. `_resolve()`'s material step
consumes a decoded texture from a separate texture-cache primitive rather than owning decode+cache
itself; terrain and NifServer both call into that primitive. Full design in
[Shared Texture Server](texture_server.md).

---

## Open to changes

- **Classification pass cost** — confirm the block-table scan is actually cheap relative to full decode
  across the real NIF corpus, not just in theory.
- **Ignored-flag signal** — silent ignore vs. a debug-only warning when `flatten_static` is requested on
  a file that turns out dynamic.
- **`NifResolveResult` shape** — not yet drafted as a concrete schema.
- **Queue vs. `call_deferred` for the attach hand-off** — `call_deferred` alone covers a single
  placement; a mutex-guarded queue is still worth it if many worker threads finish and want to attach in
  the same frame, to batch the deferred calls instead of flooding the call queue one-by-one.
- **Cache expiry policy** — the full BSA corpus is ~7GB, small enough that "keep every resolved
  `NifResolveResult` resident, evict nothing" is a real option, not just a placeholder until eviction
  gets built. Worth costing that against a TTL or LRU policy before picking one.
