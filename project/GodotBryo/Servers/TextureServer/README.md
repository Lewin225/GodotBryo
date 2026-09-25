# TextureServer

The project's one DDS decode / upload / cache primitive. Autoloaded singleton.

Design: [`Plans/Completed Plans/TextureServer/texture_server.md`](../../../../Plans/Completed%20Plans/TextureServer/texture_server.md).

Two callers need textures and neither owns a NIF — NifServer's material builder, and terrain.
Folding texture ownership into either would relocate the wrong-owner problem rather than fix it,
which is why this is a server of its own.

---

## This folder is never modified as part of other work

**Changes to TextureServer are their own task, never a step inside another one.** Every caller in
the project shares one instance, one cache and one worker budget, so a change made to suit the
caller in front of you lands on all of them. That is not visible from inside the task that caused
it.

Specifically, and each of these has already gone wrong once:

- **Do not add a method to fit one caller's call shape.** `decode()` and `upload()` were public.
  Pairing them looks like a cache and is not — `_decode()` is pure by design and consults nothing,
  only `_upload()` reads the cache — so NifServer re-read and re-decoded the DDS on every single
  call, paying 157 ms of a 174 ms 60-model build. The fix was to make the caller await, not to give
  it a synchronous shortcut.
- **Do not widen the public surface.** It is `warm()` and `request()`, plus the accessors below.
  Everything else is private because the threading split depends on it staying that way.
- **Do not change the cache key or the residency policy in passing.** The cache is process-wide and
  V1 is resident-forever; the corpus is 26,840 textures / 4.26 GB of DDS. Keying and eviction are
  memory behaviour for the whole session, not a local detail.

If work elsewhere needs something TextureServer does not offer:

1. Stop. Do not patch this folder in passing.
2. Say what is missing and what it is needed for.
3. Land it as its own change, with a test in `project/tests/servers/`.

---

## Contract

```gdscript
TextureServer.warm(tex_path, alpha_safe := false) -> void              # fire-and-forget, any thread
await TextureServer.request(tex_path, alpha_safe := false) -> ImageTexture   # coroutine
TextureServer.is_finished(tex_path, alpha_safe := false) -> bool       # terminal state
TextureServer.cache_key(tex_path, alpha_safe) -> String                # static
TextureServer.purge(...) · purge_all() · get_stats() · reset_stats()
```

**Warm, then await.** `warm()` queues without waiting and is callable from a worker — it marshals
its own enqueue through `call_deferred`. `request()` returns immediately for a resident texture,
attaches to the existing job for one already in flight, and queues one otherwise. A caller wanting
many textures warms them all first, then awaits, so they decode concurrently instead of serialising
behind one decode each.

**Requests deduplicate.** Resident means no job; in flight means an extra waiter, never a second
decode. Nothing is decoded twice for concurrent callers.

**"Finished" is not "usable".** A failed texture reaches a terminal state and its waiters get
`null`. A failure must never become a permanent blocker for whoever is waiting.

**`alpha_safe` is a distinct cache entry**, keyed `path#rgba`. It decompresses DXT1 to RGBA8,
because Godot maps `FORMAT_DXT1` to the BC1_RGB GPU format — opaque by spec — so BC1 punch-through
alpha is discarded by the sampler before any fragment shader runs. Only a shape whose
`NiAlphaProperty` actually needs that alpha should ask for it; DXT3 and DXT5 reach the GPU intact
and stay compressed.

**Threading.** `Image` is a plain pixel buffer and decodes on a worker. `ImageTexture` issues a real
RenderingServer call and is main-thread only. So `_decode()` is pure and touches no shared state,
and every cache, counter and queue is main-thread-owned — there are no atomics anywhere on the
worker path. Uploads drain in `_process()` under a per-frame budget.

| knob | default | |
|---|---:|---|
| `uploads_per_frame_budget` | 8 | uploads drained per frame |
| `upload_time_budget_usec` | 0 | `>0` time-boxes the drain instead of counting |
| `num_workers` | -1 | admission cap on concurrent decode tasks, not a thread count |

**`purge()` is manual, not a policy.** V1 is resident-forever. Measured caveat: `ImageTexture` is
refcounted, so purging frees nothing while a material still holds the texture, and the next
`request()` then decodes a *second* independent copy. It is not a memory-pressure valve without
first filtering on external reference count. An eviction policy is
[`outstanding_issues.md`](../../../../Plans/Completed%20Plans/NifServer/Implementation/outstanding_issues.md) #7.

---

## Tests

`project/tests/servers/test_texture_server.gd` — the gate. Must print `ALL CHECKS PASSED` and exit
`0` before a change here is done. It calls the private `_decode()` in places, deliberately: those
checks are about the decoder itself, including a parity check against the legacy resolver, which
the public entry points would hide behind the cache.

`project/tests/servers/test_texture_corpus_sweep.gd` — a measurement, **not** a gate. It walks every
shipped `.dds` and reports throughput; it prints a report and exits `0` rather than passing or
failing. Last run: 26,840 textures, 0 failures, 7.14 s, ~3,760 textures/sec.

```
cd project
../tools/Godot_v4.7.1-stable_linux.x86_64 --headless --path . tests/servers/test_texture_server.tscn
```
