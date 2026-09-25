# NifServer Build Order

Three servers in dependency order, ending at `res://GodotBryo/Servers/NifServer.gd`, with the
code lifted from `mesh_resolver.gd` named by line. TextureServer is a hard prerequisite, not a
parallel track — which makes the shared archive layer one too.

| | |
|---|---|
| **destination** | `res://GodotBryo/Servers/NifServer.gd` |
| **prerequisite servers** | ArchiveServer, TextureServer |
| **lift source** | `project/gamebryo/mesh_resolver.gd` (3106 lines) |
| **engine** | Godot 4.7.2 |

---

## Build order, and why it is this order

NifServer is last. It is the only one of the three with no dependents, and the only one whose
output is judged by looking at it.

| Order | File | Exists? | Why here |
|---|---|---|---|
| **1** | `ArchiveServer.gd` | No | TextureServer reads DDS from BSAs and NifServer reads NIFs from the same BSAs. With TextureServer built first, both consumers exist before either can own the layer, so duplicating the BSA-priority search across two servers is the alternative — two reader sets, two sets of file handles, one priority order to drift. It is also the single place the `pread()` thread-safety fix applies. |
| **2** | `TextureServer.gd` | No | NifServer's `_resolve()` calls `warm()` and its `_build()` consumes an uploaded `ImageTexture`. Independently verifiable before any NIF exists: `terrain3d_bridge.gd` already wants exactly this with no NIF involved. |
| **3** | `NifServer.gd` | No | Depends on both. Phases 3-6 below. |

> **The alternative, if ArchiveServer is unwanted:** TextureServer and NifServer each carry their
> own copy of `_build_bsa_order()`/`_get_reader()`/`resolve_bytes()` (~40 lines). That works and is
> faster to reach, at the cost of two independent BSA reader sets and two places to apply the
> `pread()` fix. The servers readme permits server-to-server calls, which is what makes the shared
> version clean.

---

## Two native prerequisites, neither blocking

Each gates a specific clause of the spec rather than the work itself. Each has a v1 shape that is
honest rather than a stub.

| Prerequisite | Confirmed state | Blocks | v1 shape |
|---|---|---|---|
| **BSA concurrent reads** | `bsa_archive.cpp:175-180` — `fseek()`+`fread()` on a shared `FILE*` | Concurrent `_resolve()` tasks and concurrent `decode()` tasks — both servers at once | **Mutex inside ArchiveServer.** One `Mutex` guarding `read()`, plus opening every BSA eagerly at `_ready()` rather than lazily, which removes the reader-dict write race too. Correct today, throughput-limited. Deleting the mutex is the whole change when `pread()` lands — and because the layer is shared, that is one edit rather than two. |
| **Texture slots 3-5** | `nif_reader_gd.cpp:26-28` binds three getters; `nif_loader.cpp:759-772` reads slots 0/1/2 only | The "reads all 6 slots" clause | **Native work, scheduled — not scoped out.** The format defines six slots for FNV; the loader reads three. The harvest loop iterates a slot list rather than three hardcoded calls, so slots 3-5 join it as list entries once the native getters exist. |

---

## Authored LOD drives Godot's LOD

NIFs carry authored LOD, and an authentic Godot conversion means the authored intent drives
Godot's own mechanism. Reading it is in scope; the only thing that stays out is the per-frame
decision of which level to show, which Godot already makes for us.

| Block | Carries | nifly |
|---|---|---|
| `NiLODNode` | extends `NiSwitchNode` (`flags`, active `index`), holds a `NiLODData` ref | `Nodes.hpp:377` |
| `NiRangeLODData` | `lodCenter` + per-child `LODRange { nearExtent, farExtent }` — authored switch distances | `Nodes.hpp:352` |
| `NiScreenLODData` | `boundCenter`/`boundRadius`, `worldCenter`/`worldRadius`, `proportionLevels` | `Nodes.hpp:363` |
| `BSLODTriShape` | `level0`/`level1`/`level2` over one shared `NiTriShapeData` | `Geometry.hpp:953`, `Geometry.cpp:2545` |

**The mapping.** `NiRangeLODData`'s per-child `nearExtent`/`farExtent` become
`visibility_range_begin`/`visibility_range_end` on that child's `MeshInstance3D`, converted through
`units::kGamebryoUnitsToMeters` like every other distance in this codebase. Each LOD child is built
as its own sibling carrying its own range. Godot's per-frame distance check then does the
switching — which is exactly what the authored data was expressing. No caller involvement and no
policy: the returned tree already switches correctly.

The mechanism is already proven here — `_apply_lod_visibility_range()` does this today for the
`_lod.nif` companion tiers. This applies it to the authored in-NIF data instead of a naming
convention.

**Native work required.** `native/src/nif/` reads none of these blocks today. Exposing them is an
implementation task on the way to the spec, not a reason to narrow it.

**Two parts not settled, and not to be invented:**

- `BSLODTriShape` carries triangle counts, not distances — three index ranges over shared vertex
  data with no switch ranges of its own. Where its distances come from needs establishing against
  real files: either an enclosing `NiLODNode` supplies them, or the original engine applied a
  convention.
- `NiScreenLODData` is screen-proportion based, so it has no direct `visibility_range` equivalent.
  Converting it needs the bound radius and an assumed FOV. Handle separately from the
  `NiRangeLODData` case rather than forcing both through one path.

---

## The root transform — settled

The -90° X rotation is the complete conversion. It handles the up-axis and the forward-facing
alignment in one operation, and no additional component is needed.

Forward-facing is not an independent degree of freedom: a right-handed basis has three axes, and a
rotation about X leaves right (`+X`) fixed while sending up to up — which determines where the
third axis lands. There is no free yaw left to get wrong.

| Bethesda / NIF axis | Maps to | Godot meaning |
|---|---|---|
| `+X` east / right | `+X` | right — unchanged |
| `+Y` north / forward | `-Z` | **`Vector3.FORWARD`** — Godot's own forward |
| `+Z` up | `+Y` | `Vector3.UP` |

The matrix is `(x, y, z) → (x, z, -y)`, determinant `+1` — a pure rotation, no mirroring, no
handedness change.

```gdscript
# the single place the Bethesda -> Godot convention is expressed
const ROOT_CONVERSION_BASIS := Basis(Vector3.RIGHT, deg_to_rad(-90.0))
```

**Three independent confirmations already in the repo.** `phases/0/04-dds-texture-import.md:120-127`
states the remap explicitly — "rotated -90° about X, which maps `(x, y, z) → (x, z, -y)` — the
standard axis remap" — and closes by saying the conversion should become "a first-class, permanent
part of the NIF-to-Godot pipeline rather than a one-off in a test script", which is exactly what
baking it into `_build()` does. `native/src/nif/units.h` confirms the native layer applies scale
only: "Only applies to positions/vertex coordinates. Rotation is unitless" — so geometry reaches
GDScript in Bethesda orientation and is converted exactly once. And all 20 call sites in the project
agree: `rotation_degrees.x = -90` and nothing else, with no yaw anywhere — including
`nif_viewer.gd:131`, a bare NIF preview with no REFR involved.

A caller that ends up double-rotated is a caller that kept its own `RefrRoot` after repointing — a
migration bug with an obvious signature, not an unknown in the math.

---

## Phase 1 — ArchiveServer

**One BSA layer, two consumers.** The smallest of the three and entirely lifted. Nothing here is new
logic — it is the existing BSA-priority search moved somewhere both later servers can reach it.

1. **Lift the search.** `_build_bsa_order()` (169-207), `_get_reader()` (208-226), `resolve_bytes()`
   (319-327) as `read()`, `list_files_with_prefix()` (227-252) for discovery callers. Data directory
   from `GodotBryoSettings`, not `GameDataConfigScript` — the servers readme permits settings lookups
   and forbids non-server scripts.
2. **Open eagerly, guard reads.** Every BSA opened at `_ready()` rather than on first use, removing
   the lazy reader-dict write race. One `Mutex` around `read()` until the `pread()` patch lands.
3. **Register as an autoload.** Alongside `GodotBryoSettings` and `EsmServer`, ordered before both
   servers that call it.

> **Exit criterion** — `ArchiveServer.read("meshes\\...")` returns the same bytes as a
> `GamebryoMeshResolver` built on the same data directory, for a NIF, a DDS and a WAV. Byte-identical,
> not eyeballed.

---

## Phase 2 — TextureServer

**Decode, upload, cache — provable before any NIF exists.** Full design in the Shared Texture Server
doc. What matters for ordering: this is verifiable on its own, because `terrain3d_bridge.gd` already
calls `load_texture()` for ground and normal textures with no NIF involved. That call site is the
acceptance test, not a hypothetical consumer.

1. **Lift decode.** `_tex_variant_key()` (462-463) as `_cache_key()`, `_load_image()` (474-504) as
   `decode()`, reading through `ArchiveServer`. The DXT1 decompress branch (499-502) comes with it
   unchanged — carry its one-line comment, `# For the BC1_RGBA bug`.
2. **Lift upload.** `_get_texture_from_image()` (2920-2948) as `upload()`, main-thread only, with the
   `_texture_cache`.
3. **Add the queue.** `warm()` enqueues with no waiter attached; `request()` enqueues with one, and is
   a plain cache lookup when the entry is already warm. One queue, no priority lanes. `warm()`
   marshals its own enqueue through `call_deferred`, since several worker threads may call it at once.
   Budgets: `uploads_per_frame_budget := 8`, `upload_time_budget_usec := 0`, `num_workers := -1`.
4. **Repoint terrain.** `terrain3d_bridge.gd` moves from `GamebryoMeshResolver.load_texture()` to
   `TextureServer`. First real migration, and it happens before NifServer exists — which is the point
   of building this one first.

> **Exit criterion** — Terrain renders through TextureServer with no visual difference, no RID errors,
> and the DXT1 alpha fix intact — the decal case is the one that regresses silently if the variant key
> is dropped.

---

## Phase 3 — NifServer: static geometry, synchronous, zero concurrency

A threading bug and a conversion bug produce the same screenshot. Phase 3 has no threading at all:
`_resolve()` and `_build()` exist and are called back-to-back on the main thread from a test scene.
Correctness first, concurrency second.

1. **File skeleton and registration.** `class_name NifServer extends Node`, registered as an autoload
   ordered after `ArchiveServer` and `TextureServer`. Config vars `builds_per_frame_budget := 12` and
   `num_workers := -1` declared now, unused until Phase 4. No archive code and no texture code in this
   file at all — both are calls out.
2. **NIF load and cache.** Lift `load_nif()` (401-427) as `_load_nif()` with its `_nif_cache`, reading
   through `ArchiveServer`. Keep the not-found warning — its comment documents a real
   permanently-invisible-placement bug caused by caching `null` silently.
3. **Define `NifResolveResult`.** Inner `RefCounted` class in the same file. Fields: `nif_path`,
   `flatten_static`, `mesh_entries`, `shape_entries`, `texture_requests`, `lod_entries`. Plain data and
   Resources only — no Node, no RS-backed type — so it stays worker-safe and cacheable across every
   placement.
4. **`_resolve()`, static content only.** Lift `resolve_raw_geometry()` (575-640) with two changes:
   replace the inline `_load_image()` calls (630-632) with a `TextureServer.warm()` per occupied slot,
   and drop the `load_tri()` facial-morph call (634) — humanoid work, stays out. Lift
   `_resolve_raw_collision()` (2972-2988) and `_resolve_raw_fallback_bbox()` (2989-3009) unchanged.
   - **The `alpha_safe` argument is diffuse-only.** `needs_alpha` is computed per submesh from
     `NiAlphaProperty` (596-597: `blend_enabled` or `test_enabled`) and passed only for slot 0 —
     `warm(diffuse, needs_alpha)`, `warm(normal, false)`, `warm(glow, false)`. Normal and glow alpha is
     never sampled by the materials built here (593-595), so those slots keep their compressed form.
5. **`_resolve()`, authored LOD.** Read `NiLODNode`/`NiRangeLODData` per-child extents and
   `BSLODTriShape` level counts into `lod_entries`, converting extents through
   `kGamebryoUnitsToMeters`. Gated on the native exposure work; see the authored-LOD section.
6. **`_build()`, Resources.** Lift `_build_mesh_from_raw()` (2712-2785), `_build_material_from_raw()`
   (2786-2919), `_build_collision_shapes()` (3010-3073) and its helpers `_expand_triangles()`
   (3074-3081), `_flat_to_vector3()` (3082-3088), `_basis_aligned_to_y()` (3089-3109). One change inside
   the material builder: it takes `ImageTexture` from `TextureServer` by path rather than the
   `diffuse_image`/`normal_image`/`glow_image` entries the old raw dict carried — it never calls
   `create_from_image()` itself. The `no_lighting_falloff.gdshader` preload comes with it — a resource,
   not a script, so the readme's rule is untouched.
7. **`_build()`, node tree.** Root `Node3D` carrying `ROOT_CONVERSION_BASIS`, one `MeshInstance3D` per
   submesh named from `entry["submesh_index"]` — never a loop counter, per the skipped-EditorMarker
   misattachment documented at 601-613 — and `CollisionShape3D` children from the shape entries. LOD
   children get `visibility_range_begin`/`visibility_range_end` from their authored extents. Orphaned
   and unparented on return.
8. **Thread assertion.** `assert(RenderingServer.is_on_render_thread())` at the top of `_build()`. Real
   4.7.2 API (`RenderingServer.xml:2110`); with single-threaded rendering the render thread is the main
   thread, so this catches a wrong-thread `_build()` at the call rather than as RID-table corruption
   later.

> **Exit criterion** — A test scene calling `NifServer._build(NifServer._resolve("clutter\\junk\\..."))`
> synchronously produces a textured, collidable, correctly-oriented tree that matches the same NIF
> placed through `GamebryoObjectRegistry` today. Side-by-side against the existing path, not judged
> alone.

---

## Phase 4 — NifServer: async facade, cache, budget

Nothing from Phase 3 changes shape here. `request()` is a wrapper; if Phase 3 is right, a failure in
Phase 4 is unambiguously a threading failure.

1. **The resolve cache.** One dictionary keyed `(nif_path, flatten_static)` holding `NifResolveResult`.
   Replaces the three separate identities the old file kept for one source NIF — submesh mesh cache,
   skinned-mesh cache, disk KF cache.
2. **`request()`.** Cache hit returns a fresh `_build()` of the resident result. Miss queues a
   `WorkerThreadPool.add_task()` running only `_resolve()`; the task hands its result back via
   `call_deferred`; `request()` awaits that signal and calls `_build()` itself on the main thread. Never
   `wait_for_task_completion()` — it blocks and hangs under some timing (godot#84936). Never
   `add_group_task()` at default `tasks_needed = -1`, which claims every thread in the shared pool.
3. **Build budget.** Completed results land in a main-thread queue drained in `_process()`, at most
   `builds_per_frame_budget` per frame. `num_workers` caps concurrent `_resolve()` admissions — an
   admission cap, not a thread count; `-1` resolves to `max(2, OS.get_processor_count() - 1)`, matching
   `GamebryoResolverPool._init()`.
4. **Stats.** `get_stats()` / `reset_stats()` over `resolve_cache_hits/misses`, `pending_resolve_count`,
   `pending_build_count`, `builds_this_frame`, `resident_nif_count`. Cheap, and the only way the budget
   numbers get chosen from measurement rather than guess.
5. **`flatten_static`.** The block-table enumeration always runs. With the flag set and no skin or
   controllers present, skip the per-block skin and keyframe decode and pool geometry into merged
   world-space buffers. With skin or controllers present the flag is ignored — content decides, not the
   caller's guess.

> **Exit criterion** — Many placements of many distinct NIFs stream in through
> `await NifServer.request(...)` with no RID errors, no frame spikes beyond the budget, and cache hits
> climbing on repeat base objects. This is the first point the physicaliser's `StaticReference` path
> could repoint — the bulk of cell content.

---

## Phase 5 — Skeleton, skinning, in-NIF controllers

1. **Skeleton from scene nodes.** Lift `_build_skeleton_from_scene_nodes()` (1201-1286),
   `populate_skeleton()` (1023-1043). A code-built `Skeleton3D` needs `reset_bone_poses()` or every bone
   renders pinned to world origin.
2. **Skinned geometry.** Lift `populate_skinned_geometry()` (1044-1071) and
   `_build_skinned_mesh_from_raw()` (1664-1700). Surfaces carrying `ARRAY_BONES`/`ARRAY_WEIGHTS` must
   never be served to a non-skinned build of the same submesh — in the one-cache model that is a
   distinct cache key, not a second cache.
3. **Controllers and the dynamic tree.** Lift `populate_dynamic_children()` (859-1022),
   `populate_animation_player()` (1868-1903), `populate_direct_controller_player()` (1904-1951). This is
   where `owning_node_index` earns the threading-through the old file does — a wrong index silently
   attaches a submesh under the wrong node.

---

## Phase 6 — `request_kf()`

1. **Sequence conversion.** Lift `_build_sequence_animation()` (2361-2453) and its helpers
   `_godot_interp()` (2474-2487), `_resample_axis_rotation()` (2488-2507), `_eval_float_keys_linear()`
   (2508-2531). Strip the `Skeleton3D` parameter and the `resolve_target_path` Callable — tracks get
   bare authored names (`NodePath("Bip01")`) and binding is caller-side.
2. **Worker-safe by construction.** `Animation` is not RS-backed and its `NodePath` tracks need not
   resolve at construction time, so `request_kf()` returns from the worker with no `_build()` stage at
   all.
3. **`request_retargeted_kf()` stays a stub.** Returns not-implemented. It is `request_kf()` plus a
   rename loop; it gets built only if profiling shows that loop is expensive on the main thread.

---

## What does not move into this file

These are why `mesh_resolver.gd` reached 3106 lines, and leaving them out is what keeps NifServer a
single file. Each becomes a caller of `request()` rather than a mode inside it.

| Concern | Lines | Where it goes |
|---|---|---|
| Humanoid multi-file stitching, head/hair parts | 1072-1199, 1287-1425 | Caller — actor assembly |
| Equipment and armor slots | 1426-1589 | Caller — actor assembly |
| FaceGen EGM / TRI morphs | 329-400, 1590-1663, 1701-1815 | Caller — actor assembly |
| `_lod.nif` companion lookup and crossover tuning<br>*Distinct from authored in-NIF LOD, which is in scope. 440-451 finds a separate file by filename convention; 2532-2598 are project tuning distances supplied via `set_lod_crossover()`. A caller wanting the companion asks for it as its own NIF path.* | 440-451, 2532-2598 | Caller — streaming |
| Rigid body mass and physics policy | 2619-2711 | Caller — physicaliser |
| Sound loading | 528-574 | Unrelated to NIF — stays or becomes its own server |
| Animation discovery / clip sets | 253-318, 2052-2252 | Caller — actor animation |
| `populate_locomotion_tree()` | 2253-2321 | Already dead — `push_error`; superseded by the authored actor scene |
| REFR placement transforms<br>*NifServer is never passed REFR data and returns an origin-centred tree; the caller places it.* | 2949-2971, 3110-3114 | Not lifted — stays in `mesh_resolver.gd` for its existing callers. A caller that repoints drops its own `refr_root_basis()` composition, since the returned tree is already conformant, and keeps only its position/rotation/scale placement. |

---

## Decisions this plan does not make

- **File naming.** The repo uses snake_case for scripts (`esm_server.gd`, `mesh_resolver.gd`,
  `esm_reference_physicaliser.gd`). `NifServer.gd` as named breaks that; `nif_server.gd` with
  `class_name NifServer` matches it. Cosmetic, but it now applies to three files, so pick before any of
  them exists rather than renaming later.
- **Cache expiry.** The corpus is small enough that keeping every resolved result resident and evicting
  nothing is a real option. Worth costing against TTL or LRU with Phase 4's `resident_nif_count` before
  choosing, rather than building eviction on principle.
- **Attach hand-off shape.** `call_deferred` alone covers a single placement. A mutex-guarded queue
  batching the deferred calls is worth it only if many workers finish in one frame — measurable in
  Phase 4, not before.
- **Disk cache.** Serialized `NifResolveResult` under the same key plus a content hash. Nothing in
  Phases 1-6 depends on it; it is an optimisation on a working cache, not part of the build.
