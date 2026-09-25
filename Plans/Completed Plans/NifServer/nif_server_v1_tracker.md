# NIF Server Design Discussion Tracker

This file lists questions, contradictions, and verification tasks found while reviewing
`nif_server.md`. It records issues for discussion; it does not decide them or silently change the
NIF Server plan.

## Contract and scope

- [x] **Public API completeness:** `request(nif_path, flatten_static)` targets the best implemented
  Godot tree for the NIF's actual contents, with feature parity against the existing
  `mesh_resolver` paths. The purpose of NifServer is to unify those working features behind one API;
  implementation phases may stage delivery, but the final public contract is not static-only.
- [x] **Failure contract:** NIF validity is not conditional on renderable geometry. A valid,
  parseable NIF—including an animation-only KF-style NIF—must produce its best Godot representation
  even if it has no `MeshInstance3D` children. Missing or malformed input returns `null`; unsupported
  optional features produce a partial representation plus diagnostics. Warnings should be emitted once
  per canonical path, with detailed diagnostics available separately from the simple `Node3D`/`null`
  consumer result.
- [x] **Cancellation/lifetime:** The physicaliser creates the typed `EsmNode` immediately and starts
  visual construction asynchronously. The typed node is the lifetime owner; it may exist for several
  seconds before its visual child appears without stalling the game. NifServer may finish worker/cache
  work, but must check that the owner node still exists before building or delivering the visual. No
  caller-managed cancellation is required for ordinary cell/reference teardown.
- [x] **Delivery contract:** Use an owner-aware callback rather than an awaitable orphan-node return:
  `NifServer.request(nif_path, owner: Node, on_complete: Callable, flatten_static := false)`. The
  callback is a method on `owner` (not a closure that captures it), is invoked exactly once on the main
  thread when the owner and callback target are still valid, and receives the built `Node3D` or `null`
  for a fatal NIF failure or shutdown cancellation. If the owner is gone, NifServer skips `_build()` and
  does not create an orphan. A successful callback transfers ownership of the visual to the caller,
  which must parent or free it immediately; NifServer verifies that postcondition and frees an unparented
  live result.
- [x] **Ownership contract:** Before delivery, NifServer owns the built visual. A valid callback must
  immediately parent or free it; NifServer then verifies that the node is either freed or parented and
  calls `queue_free()` as a safety net if a valid node remains orphaned. NifServer does not choose the
  parent, so typed nodes may attach the visual below the appropriate body/equipment/skeleton child.
  No explicit `release()` API or node-instance tracking is needed.
- [x] **Canonical paths:** NifServer accepts the natural ESM model-reference form and may also accept
  the same path with a leading `meshes\\`/`meshes/` prefix. Examples include
  `furniture\\NoVac_bedqueen.NIF`,
  `Weapons\\2HandRifle\\MicroFusionCell.NIF`,
  `architecture\\paradisefalls\\doors\\paradisefallsdoor01.nif`, or
  `armor\\bigbattle\\RangerBattlearmor.NIF`. Before cache lookup, case and slash direction are
  normalized (`\\` → `/`, lowercase) and a leading `meshes/` is stripped. Thus both forms have one
  canonical cache identity, and ArchiveServer adds `meshes/` exactly once. Empty paths are invalid
  requests.

## Worker/main-thread boundary

- [x] **Result contents:** v1 `_resolve()` returns only the conservative, definitely worker-safe raw
  data required to build the best Godot tree. `NifResolveResult` contains no scene nodes, render/physics
  resources, decoded Images, parser handles, or server objects. TextureServer remains the texture
  dependency and contract.
- [x] **Image ownership:** Decoded `Image` values belong to TextureServer and do not cross through
  NifServer's result. NifServer records texture requests and uses TextureServer's existing warm/request
  contract.
- [ ] **v2 off-thread node work:** After v1 is correct and profiled, investigate moving additional
  off-tree scene-chunk construction into a controlled thread. Test one-thread and multi-request cases
  separately, including shared Resource access, rendering-node setup, collision setup, callback handoff,
  and shutdown. This is an optimization investigation, not a v1 assumption.
- [x] **V1 construction/cache strategy:** Keep the proven old-resolver shape for v1: cache parsed/raw
  NIF data and reusable main-thread Resources, then construct a fresh visual node tree for each delivered
  instance. Do not introduce cached orphan prototype trees or `Node.duplicate()` into the initial
  implementation.
- [x] **Texture readiness:** The settled ordering is: (1) NIF resolution sends every texture variant
  to `TextureServer.warm()`; (2) after the result reaches the main thread, NifServer checks every
  `TextureServer.is_finished(path, alpha_safe)` key; (3) it hands the result to `_build()` only when
  all keys are finished; (4) `_build()` calls `TextureServer.request(path, alpha_safe)` again and
  receives the cached usable texture immediately, or `null` for a terminal failure. “Finished” includes
  success and failure; “ready” means a usable result and is not used as the synchronization predicate.
  NifServer does not implement a second cache or deduplication layer; TextureServer owns request
  caching and in-flight deduplication.
- [x] **Cross-server calls:** Worker `_resolve()` may call the explicitly thread-safe
  `TextureServer.warm(path, alpha_safe)` API, which internally marshals queue mutation, then returns
  immediately without waiting. On the main thread, NifServer checks `is_finished()` and calls
  `request()` only after all texture jobs finish. Workers never wait on TextureServer or inspect its
  state, preventing wasted worker slots and shared-pool deadlocks.
- [x] **Archive concurrency:** Use positional native reads up front: `pread()` on POSIX and
  `ReadFile()` with an `OVERLAPPED` offset on Windows. BSA extraction is read-only, so one opened archive
  can serve concurrent NifServer/TextureServer reads without a cursor mutex or per-worker readers.
  Open/index archives before accepting requests and keep the catalog immutable thereafter. Include
  concurrent real-data extraction tests and platform-specific error handling.
- [x] **Archive index ownership:** `BsaArchive` retains its per-archive normalized index. A native
  immutable archive catalog owns the opened archives, BSA priority, and global normalized path → compact
  archive/entry index, with prefix enumeration using the same winner rule. A thin GDScript
  `ArchiveServer` autoload owns configuration and lifecycle only. Loose-file precedence remains an
  explicit separate policy question in `Plans/Completed Plans/ArchiveServer/archive_server.md` and is not assumed for v1.
- [x] **GDScript concurrency:** V1 worker tasks use private `NifReader` instances and private local
  Arrays/Dictionaries/PackedArrays while resolving. They publish a fresh immutable plain-data result;
  the main thread only reads it. Shared NifServer caches, queues, and counters are main-thread-owned.
  Workers may use only the explicitly thread-safe `ArchiveServer.read()` and `TextureServer.warm()` APIs;
  decoded Images remain TextureServer-owned. No shared container is resized or mutated across threads.
  Editor/debug policy and diagnostics are captured/returned as data rather than queried or mutated from
  worker code.

## Queueing, async behavior, and budgets

- [x] **Build queue contradiction:** The public API is callback-based. `request()` queues `_resolve()`;
  the main thread waits for TextureServer completion, then places the result in the build queue.
  `_process()` alone drains that queue within `builds_per_frame_budget`, calls `_build()` on the main
  thread, and invokes the owner callback afterward. Cache hits also use this queue because v1 creates a
  fresh visual node tree per delivered instance. No blocking task wait is used.
- [x] **Cache-hit pacing:** Cache hits still consume the build budget because v1 creates a fresh visual
  node tree for every delivered instance. They skip archive/NIF/texture work but do not bypass main-thread node construction. The count budget provides pacing, while real measurements determine whether a future time budget or cost-based lanes are needed. May change if final orphaned tree's are found to be cachable
- [x] **Texture/NIF queue interaction:** TextureServer and NifServer keep independent worker/build
  queues. NifServer workers warm textures and return immediately; TextureServer progresses decoding and
  budgeted uploads independently. NifServer's main-thread build queue admits only texture-finished
  results and skips waiting entries to avoid head-of-line blocking. Neither server waits on or calls back
  into the other, and failed textures are terminally finished rather than blockers.
- [x] **Admission accounting:** Admission is main-thread-owned and capped by active `_resolve()` task
  count. `num_workers == -1` uses the automatic cap; every other non-positive value clamps to one.
  Identical canonical `(nif_path, flatten_static)` requests share one in-flight record with multiple
  callback waiters. A slot is acquired immediately before task submission and released when the worker
  result is handed back to the main thread; texture waiting and building do not occupy it. Runtime cap
  changes affect future admissions only: active tasks continue, lowering pauses new starts, and raising
  resumes queued work.
- [x] **Task completion hand-off:** Each admitted resolve receives a unique request ID and main-thread-
  owned in-flight record. The worker runs only `_resolve()` and posts the immutable result with
  `call_deferred()`; the main-thread handler validates the record, releases the resolve slot, begins
  texture monitoring, and admits queued work. Duplicate requests append callback waiters to the same
  record; each still-valid waiter later gets its own build entry. Stale completions are ignored, callbacks
  run at most once on the main thread, and expected native/parse failures must return completed result
  envelopes so no request remains stranded.
- [x] **Shutdown:** Stop admitting new requests, mark pending requests as terminally cancelled, and
  invoke each still-valid owner callback exactly once with `null`; do not silently remove pending
  callbacks. Skip callbacks whose owner or target is gone. Cancelled requests perform no texture wait or
  build work. Track WorkerThreadPool task IDs so running workers can finish without blocking the main
  thread; ignore their stale deferred completions after the in-flight records are cleared, and ensure
  shutdown ordering keeps the server alive until those deferred calls are harmless.
- [x] **Stats:** `get_stats()` returns a main-thread-owned snapshot separating cumulative counters from live gauges. 
  `resolve_cache_hits` counts requests finding an existing cached result, including a cached failure; 
  `resolve_cache_misses` counts requests with no cached result; 
  `duplicate_waiter_count` counts requests joining an existing in-flight resolve; 
  `resolve_failure_count` counts terminal resolve failures (with failure reasons where practical); 
  `pending_resolve_count` is active worker resolves;
  `pending_texture_count` is results waiting for TextureServer completion; 
  `pending_build_count` is texture-finished results waiting for `_build()`; 
  `resident_nif_count` is unique cached keys, including cached failures; 
  `builds_this_frame` is the current-frame `_build()` count; 
  `total_build_count` is the cumulative build count; 
  `texture_wait_usec` is cumulative texture-wait time; and
  `shutdown_cancel_count` counts requests completed with `null` during shutdown. 
  `reset_stats()` clears cumulative counters but leaves live queue/cache gauges accurate.

## `flatten_static`

- [x] **Meaning of “flatten”:** `flatten_static=true` returns one wrapper `Node3D` containing one
  `MeshInstance3D` for every mesh in the NIF. It removes the authored scene hierarchy; it does not merge
  meshes into one buffer. Each mesh keeps its own surfaces and material assignments.
- [x] **Coordinate space:** Mesh transforms are represented relative to the returned wrapper/root, and
  the caller remains responsible for placement. No world-space coordinates are baked into the result.
- [x] **DirectGeometryBatch:** Flattening never uses `DirectGeometryBatch`; that remains a separate
  placement/batching API because this request contract returns a `Node3D` tree.
- [ ] **Future static batching:** A separate function that combines static content into one mesh may be
  useful later, but it is not part of `flatten_static` and will not be implemented speculatively.
- [x] **Material compatibility:** No cross-mesh merge is performed, so no material-compatibility test is
  needed. Preserve each mesh's authored material/surface state, including its texture variants and
  render parameters.
- [x] **Collision:** Each flattened `MeshInstance3D` receives its corresponding authored collision when
  one is available and applicable. Flattening changes the visual hierarchy only; it does not discard
  applicable collision data.
- [x] **Dynamic detection:** `flatten_static=true` is an explicit caller override. It flattens dynamic
  NIFs too, intentionally discarding their dynamic behavior; detection remains useful for deciding what
  data to skip and for diagnostics, but must not silently switch the request back to full mode.
- [x] **Cache identity:** Full and flattened results are distinct cache entries keyed by
  `(canonical_path, flatten_static)`, because the caller explicitly requested different representations.

## Scene hierarchy, skinning, morphs, and animation

- [ ] **Result schema:** Draft the complete full-mode schema for scene nodes, mesh entries, ownership
  indices, collision descriptors, skin data, morph data, controller sequences, direct controllers,
  diagnostics, and texture requests. Include required `is_flattened: bool` metadata so consumers can
  inspect the effective result shape without reconstructing the request mode. The `flatten_static=true`
  schema branch is intentionally cheaper:
  it extracts only mesh and applicable collision data, does not inspect or preserve the scene hierarchy,
  skinning, morph, or animation data, and lets `_build()` create the single wrapper with one mesh
  instance per mesh.
- [ ] **Dynamic tree fidelity:** Confirm how the NIF root, root-attached nodes, duplicate/empty names,
  parent cycles, and owning-node indices map to valid Godot node paths.
- [ ] **Skinned construction:** Define whether one result can instantiate both ordinary and skinned
  submeshes, how `Skin` resources are created, and how external humanoid skeletons are supplied.
- [ ] **Morph policy:** Decide whether NIF morph geometry and animation belong in NifServer or remain
  actor/FaceGen caller responsibilities. Do not drop morph data accidentally while removing TRI/EGM
  actor-specific work.
- [ ] **KF contract:** Verify whether constructing and mutating `Animation` on a worker is supported by
  this Godot version. Define cache identity, missing-file behavior, sequence selection, and whether
  `request_kf()` returns one clip, a clip set, or a sequence map.
- [ ] **Animation-only NIF representation:** Decide whether `request()` on a KF/animation-only NIF
  returns a valid root with an `AnimationPlayer`/embedded animation representation, or whether such
  files are valid only through the separate `request_kf()` API. Either way, parse validity must not be
  conflated with presence of meshes.
- [ ] **Track binding:** Confirm the exact bare-path convention and caller-side binding rules for scene
  nodes, Skeleton3D bones, visibility tracks, direct controllers, and morph tracks.
- [ ] **Retargeting:** Decide whether `request_retargeted_kf()` is intentionally absent from v1, returns
  a documented unsupported result, or is implemented as a main-thread rename operation.

## Materials and texture slots

- [ ] **Slots 3–5 scope:** The plan says NifServer reads height, environment, and environment-mask
  slots, but the current material path does not render them. Decide whether v1 only preserves/diagnoses
  those slots or also adds the required shader/material behavior.
- [ ] **Native exposure:** Verify the real FNV slot count and add native getters only after checking
  the supported NIF versions and actual shipped data. Avoid treating Skyrim-only slot behavior as FNV
  behavior.
- [ ] **Texture request descriptors:** Define whether the descriptor carries slot number, alpha-safe
  variant, sampler role, source path, and failure state rather than only `{path, alpha_safe}`.
- [ ] **Material cache ownership:** Decide whether materials are cached by NifServer, TextureServer,
  a separate material server, or per-result. Include shader parameters and null-material cases in the
  identity.
- [ ] **Alpha and normal-map policy:** Reconfirm the diffuse-only alpha-safe rule and document the
  normal-map green-channel convention, rather than carrying either assumption forward silently.

## LOD and transforms

- [ ] **Root conversion:** Reconfirm the single `-90° X` conversion with numeric tests for vertices,
  child transforms, collision, animations, and caller placement. Define exactly which migration callers
  must remove their existing conversion and when.
- [ ] **Authored in-NIF LOD:** Do an exhaustive census before committing to support. The proposed
  `NiRangeLODData` mapping is not yet validated against the project's real FNV corpus.
- [ ] **`BSLODTriShape`:** Determine whether its level triangle counts have usable distances from an
  enclosing node/data block. Do not invent crossover distances.
- [ ] **`NiScreenLODData`:** Decide whether it is unsupported, approximated with an explicitly chosen
  camera/FOV policy, or implemented with a custom visibility mechanism.
- [x] **Companion `_lod.nif`:** `NifServer.request_lod()` explicitly resolves a canonical
  `foo.nif` to archive-backed `foo_lod.nif`, then delegates to the ordinary exact-path request.
  The helper caches both hits and misses and returns `null` rather than silently falling back to the
  full model. VWD policy, distance bands and full/LOD handover stay with the caller. The WastelandNV
  census found all 358 distinct companions rooted at `BSFadeNode`, with no in-file LOD selector;
  NifServer's normal root conversion is therefore the only model-space conversion involved.

## Caching, persistence, and migration

- [ ] **V2 prototype-tree cache:** Benchmark caching a fully constructed orphan visual prototype and
  serving instances with `Node.duplicate()`. Measure duplication against fresh node construction for
  static, dynamic, skinned, morph, animation, and collision trees, including Resource identity,
  per-instance state reset, memory retention, and the existing build budget. Only adopt it if the real
  data/profile shows a meaningful win.

- [ ] **Cache layers:** Decide whether “one cache” means one NIF resolve cache only, while mesh,
  material, texture, animation, and collision Resource caches remain separate implementation details.
- [ ] **Null caching:** Define whether missing/unparseable NIFs and textures are cached, for how long,
  and how a later loose-file/mod/data refresh invalidates them.
- [ ] **Eviction:** Choose resident-forever, LRU, TTL, or an explicit purge API. Include resource
  references held by instantiated nodes and TextureServer/Terrain3D texture slots.
- [ ] **Disk cache:** Decide whether serialized results are v1 scope. If so, define format version,
  source/archive content hash, engine/native parser version, and whether packed arrays are portable.
- [ ] **Migration boundary:** List every current `GamebryoMeshResolver` caller and the replacement
  adapter needed for static, dynamic, skinned, humanoid, terrain, rigid-body, and direct-RID paths.
  Confirm that old and new paths can coexist without double axis conversion or duplicate resource work.

## Verification gates

- [ ] **Corpus selection:** Define representative and exhaustive datasets for static, dynamic, skinned,
  morph, KF, collision, material, LOD, missing-file, and duplicate-placement cases.
- [ ] **Parity tests:** Compare NifServer output against the current resolver numerically for transforms,
  vertex counts, indices, materials, collision descriptors, skeleton binds, and animation tracks before
  relying on screenshots.
- [ ] **Thread tests:** Run concurrent real-data resolve/decode tests and verify no shared cursor,
  cross-thread Godot object, RID, or deferred-callback failures.
- [ ] **Frame-budget tests:** Prove that build and upload counts/time remain within configured budgets,
  including cache hits, duplicate waiters, missing textures, and a queue backlog.
- [ ] **Visual tests:** Use close-up and placement-sensitive real scenes, not a single fixed-angle image,
  for axis conversion, dynamic hierarchy, alpha, normal maps, collision, LOD, and repeated instances.
