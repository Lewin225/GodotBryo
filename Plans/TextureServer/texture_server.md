# Shared Texture Server

*Clean-slate design.*

Same thread/cache/return-when-ready shape as [NIF Server](../NifServer/nif_server_v2.md), applied to textures — one
decode-and-upload primitive, used by NIF Server's material step *and* the terrain streamer, instead of
each owning its own.

| | |
|---|---|
| **replaces** | `mesh_resolver._load_image`/`_get_texture_from_image` + terrain's direct `resolver.load_texture()` calls |
| **companions** | [NIF Server](../NifServer/nif_server_v2.md) · [NifServer Build Order](../server_stack_build_order.md) · Mesh Resolver Refactor (pin-down) |
| **status** | design sketch |

---

## Why this is its own thing

`mesh_resolver.gd`'s texture decode/cache is already used by something that has no NIF at all —
`terrain3d_bridge.gd` calls `resolver.load_texture()` directly for ground and normal-map textures.
Folding texture ownership into NIF Server would relocate the same wrong-owner problem rather than fix
it; it earns a primitive of its own.

```gdscript
# the entire public surface
TextureServer.warm(tex_path: String, alpha_safe: bool = false) -> void            # fire-and-forget, any thread
TextureServer.request(tex_path: String, alpha_safe: bool = false) -> ImageTexture # coroutine, await-able
TextureServer.is_finished(tex_path: String, alpha_safe: bool = false) -> bool     # terminal state, success or failure
TextureServer.cache_key(tex_path: String, alpha_safe: bool) -> String             # static
TextureServer.purge(...) · purge_all() · get_stats() · reset_stats()
```

`decode()` and `upload()` are **private** (`_decode`/`_upload`). They were public, and the pairing was
a trap: `_decode()` is pure by design and consults no cache, so `decode()` then `upload()` re-read and
re-decoded the DDS on every call, with only the GPU upload deduplicated. NifServer used them that way
and paid 157 ms of a 174 ms 60-model build for it. There is no synchronous route in: a caller warms,
then awaits `request()`.

| state (by cache key) | `warm()` | `request()` |
|---|---|---|
| `cold` | inserts a new job into the queue, no waiter attached | inserts a new job into the queue, attaches a waiter, **awaits** its completion signal |
| `warming` | no-op — job already queued/in-flight | attaches a waiter to the existing job, **awaits** its completion signal |
| `warm` | no-op — already resident | **pure cache lookup** — returns the resident `ImageTexture` immediately, no queue interaction at all |

> **Callable from any thread.** `warm()` marshals its own enqueue through `call_deferred` internally
> rather than mutating the pending-queue directly — safe to call from a worker thread without the
> caller needing to know or care.

---

## Two callers today, duplicated; one primitive tomorrow

**Today**
- NIF materials: `_load_image()` → `_get_texture_from_image()`, cached inside `mesh_resolver`
- Terrain: calls the same resolver's `load_texture()` directly — no NIF touched, just reusing the only
  decode path that exists
- Terrain's `prewarm_textures()` walks the full worldspace grid fully synchronously — confirmed no
  `Thread`/`WorkerThreadPool` use anywhere in `terrain3d_bridge.gd`

**With TextureServer**
- one decode+cache owner, called by both — NIF material builder and terrain stop each owning a copy of
  the same DXT1/mipmap/BSA-lookup logic
- terrain's prewarm loop gets real off-thread decode for free, by becoming a caller instead of the thing
  that invented synchronous loading in the first place
- `Terrain3DTexturePool` (the GPU array-texture slot assignment, keyed by `Texture2D`) is unaffected —
  it already sits one layer above this and keeps working once it's handed the same shared, deduped
  `ImageTexture`

---

## Threading split — same constraint as NIF Server, same reason

**Worker thread — `_decode()`**
- BSA lookup + DDS bytes
- `Image.load_dds_from_buffer()`, DXT1 alpha-safe decompress + mip regen when needed
- returns a plain `Image` — pixel buffer, no RID

→

**Main thread — `_upload()`**
- `ImageTexture.create_from_image()` — an RS call, cannot move off main
- cached by the same key `_decode()` used, so repeat callers hit cache instead of re-uploading

> Same constraint as [NIF Server](../NifServer/nif_server_v2.md)'s: `mesh_resolver.gd`'s own top-of-file comment
> documents a real, repeatable RID-table-corruption crash from constructing RS-backed Resources
> (ArrayMesh, ImageTexture, StandardMaterial3D, Shape3D) off the main thread, with this project's
> Separate Rendering Thread model off. `_decode()` stops at `Image` for exactly that reason.

> The pooling shape already exists too — `GamebryoResolverPool`/`GamebryoResolveContext` run private
> per-worker raw caches merged into one main-thread owner. TextureServer is that same pattern,
> generalized to a standalone class instead of living inside the mesh resolver.

---

## Hard rule: never claim the whole shared pool

Per Godot's own `WorkerThreadPool` docs: `add_group_task()`'s `tasks_needed` parameter defaults to
`-1`, which the docs state plainly: *"the default value -1 means it is distributed to all worker
threads."* If either this server or [NIF Server](../NifServer/nif_server_v2.md) ever batches its own work through
`add_group_task()` at that default, it occupies *every* thread in the one shared pool for the group
task's full duration — and since both servers submit into that same pool, the other server's tasks
(texture decode, or NIF resolve) simply cannot be scheduled at all until it finishes. Combined with the
"no lazy reference" constraint — `_build()` genuinely can't proceed without a real uploaded texture —
that's not a stall, it's a hang: NifServer waiting on a texture that TextureServer can never get a
thread to produce.

> Godot's own docs independently confirm the general shape of this hazard:
> `wait_for_task_completion()`/`wait_for_group_task_completion()` return `ERR_BUSY` specifically *"if
> the call is made from another running task and, due to task scheduling, there's potential for
> deadlocking."* The engine already refuses to let a task block-wait on another task from within a
> running task for exactly this reason — treat an all-threads group task as the same class of hazard,
> since nothing catches it the way `ERR_BUSY` does.

> **The rule, plainly:** neither server may call `add_group_task()` with the default (or any)
> `tasks_needed` that could claim the whole pool. `_resolve()`/`_decode()` stay ordinary `add_task()`
> calls bounded by each server's own `num_workers` — which queue fairly and free their slot as each
> finishes, never claiming exclusive access — and neither server ever calls a blocking
> `wait_for_*_completion()` from inside one of its own running tasks (already the design, via
> `call_deferred` + signal). If a future caller wants real group-task parallelism (batch-resolving many
> placements at once, say), it must pass an explicit, capped `tasks_needed` that leaves headroom for the
> other server — never the default.

---

## Self-contained: owns its own budget, not WorldStreamer's

The `_upload()` gate needs a per-frame budget — the same throttling reason `world_streamer.gd` already
caps `objects_per_frame`/`tiles_per_frame` (a real perf report: 57 tiles starting in one tick,
unthrottled). The budget lives *inside* `TextureServer`, not as an external caller pacing its own calls
— the server keeps its own pending-upload queue, drains up to its own budget per frame, and every
`request()` just awaits its turn. That's what makes it a standalone component with a defined contract
instead of logic split between the server and whoever happens to drive it.

```gdscript
# tuning — exported, so a debug tab or profiler can adjust live
@export var uploads_per_frame_budget: int = 8
@export var upload_time_budget_usec: int = 0   # 0 = count-based only; >0 = time-box instead
@export var num_workers: int = -1   # concurrent-task ADMISSION CAP, not a thread count —
                                    # WorkerThreadPool's real OS threads are fixed at
                                    # project startup and never resized (see below).
                                    # -1 = auto: max(2, OS.get_processor_count() - 1),
                                    # same convention as GamebryoResolverPool._init()

# perf/queue surface — same shape as mesh_resolver's own
# get_cache_stats()/reset_cache_stats(), extended with queue depth
TextureServer.get_stats() -> Dictionary
  # { decode_cache_hits, decode_cache_misses,
  #   upload_cache_hits, upload_cache_misses,
  #   pending_queue_count,      # one queue, warm() and request() jobs alike
  #   uploads_this_frame, resident_texture_count,
  #   warm_attach_count }  # request() calls that attached to a job an
                           # earlier warm() had already queued — the number
                           # that actually proves lookahead is working
TextureServer.reset_stats() -> void
```

> Consequence worth stating plainly: with a real budget, `request()` can now take multiple frames to
> resolve when the upload queue is backed up beyond budget — not just "worker decode time." Same
> tradeoff `tiles_per_frame` already accepts; a caller awaiting `request()` just sees a longer wait,
> never a wrong result.

---

## Cache key — carried over unchanged

The existing DXT1-alpha fix depends on a specific cache identity: a texture decoded for an alpha-safe
(unlit/scissor) use has to stay a distinct cache entry from the same path decoded normally, or the two
uses collide and reintroduce the black-background bug this project already fixed once. TextureServer
keeps that key verbatim.

```gdscript
static func _cache_key(tex_path: String, alpha_safe: bool) -> String:
    return tex_path + "#rgba" if (alpha_safe and tex_path != "") else tex_path
```

---

## Decisions

Settled 2026-09-12 (Stage C of `Plans/server_stack_build_order.md`). Each is cheap to revisit.

| question | decision |
|---|---|
| Own pool, or extend `GamebryoResolverPool`? | **Own admission cap over `WorkerThreadPool`.** The `pread()` patch (Stage A) removed the need for per-worker `BsaArchive` contexts entirely, so a pool-of-contexts would carry no weight. |
| `num_workers` semantics | An **admission cap on this server's own in-flight tasks**, not a thread count. `WorkerThreadPool`'s real OS threads are fixed at project startup; both servers submit into that one shared pool, and ordinary `add_task()` calls queue rather than oversubscribe. |
| Cache expiry | **Resident-forever for V1**, decided once here and applying to NifServer too. The total texture set is small enough that eviction is not yet worth its complexity; revisit only against a measurement. |
| Terrain's migration path | **Out of scope for this stage.** Build the primitive; repointing `terrain3d_bridge.gd` is later work and must not be bundled with it. |
| Where `alpha_safe` is decided | **The caller decides**; the server takes it as an argument. The NIF material builder derives it from `NiAlphaProperty`; terrain passes `false`. |

### Carried over verbatim, not reimplemented

The DXT1 alpha handling in `mesh_resolver._load_image()` is a previously-fixed bug, not new code:
DXT1 is decompressed to RGBA8 **only** when `alpha_safe`, kept under a distinct `#rgba` cache key so
the compressed form survives for non-alpha uses, with a mipmap-regeneration guard. Getting either the
key or the branch wrong silently reintroduces the black-background decal bug. The gate asserts both
directly rather than trusting the port.

### Still open

- [ ] Repointing terrain and the NIF material path to this server.
- [ ] Whether `upload_time_budget_usec` should replace the count budget by default, once measured.
- [ ] **A real eviction policy.** `purge(path, alpha_safe)` / `purge_all()` exist as manual,
  caller-driven eviction. There is no policy: V1 is resident-forever, and the corpus sweep imposes
  its own sliding window rather than the server doing so.

  Measured footprint (`tests/servers/test_texture_corpus_sweep`, headless, `alpha_safe=false`):

  | | |
  |---|---:|
  | `.dds` entries (catalog winners) | 26,840 |
  | BSA-stored (zlib) bytes | 3.00 GB |
  | actual DDS bytes, ≈ resident footprint | **4.26 GB** |
  | mean / largest texture | 166 KB / 10.7 MB |
  | whole corpus resident, peak process memory | **4.88 GB** |
  | throughput, resident-everything vs purging | 3,847 vs 3,965 tex/s |

  Holding the whole set does **not** fail on a dev machine — an earlier note here claiming it would
  OOM was wrong, and assumed a DXT1→RGBA8 expansion that only happens when `alpha_safe` is set.
  Purging buys footprint, not speed.

  Two constraints on whatever policy replaces this:

  - **Byte budget, not count.** A 64× spread between mean and largest texture makes a count cap a
    poor proxy for memory.
  - **Eviction must respect holders.** `ImageTexture` is refcounted, so dropping the cache entry
    does not free VRAM while a material still holds it — and the next `request()` then decodes a
    **second independent copy**. Demonstrated directly: purging a texture held by a
    `StandardMaterial3D` and re-requesting it returns a different instance. A naive eviction pass
    during play can therefore *increase* memory and silently de-duplicate shared textures into
    per-caller copies. Candidates must be filtered by external reference count.

  LRU under a byte watermark fits both constraints; FIFO evicts the longest-lived working set, and
  TTL does not respond to pressure. Not yet decided.
