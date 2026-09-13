# NifServer

Turns one NIF file into one Godot node tree. Single path, no per-caller flags, no special cases for
actors, doors or terrain.

Design: [`Plans/NifServer/nif_server_v2.md`](../../../../Plans/NifServer/nif_server_v2.md).
Corpus research behind it: [`Plans/NifServer/Research/`](../../../../Plans/NifServer/Research/).

---

## This folder is never modified as part of other work

**Changes to NifServer are their own task, never a step inside another one.** A change here is
correct only against the whole shipped corpus, not against the model that prompted it — 25,307
NIF/KF files, 20,542 of them `.nif`. A fix that makes one mesh look right and quietly breaks a
class of others is the failure mode this rule exists to prevent, and it is not visible from inside
the task that caused it.

If work elsewhere needs something NifServer does not return:

1. Stop. Do not patch this folder in passing.
2. Say what is missing and what it is needed for.
3. Land it as its own change, with a corpus census sizing the affected population and a test in
   `project/tests/servers/`.

The same applies to `native/src/nif/nif_source.{h,cpp}` and `nif_source_gd.{h,cpp}`, which are the
native half of this server. 

`native/src/nif/nif_loader.{h,cpp}` is **not** part of NifServer — it is
the legacy pre-digested reader still serving `mesh_resolver.gd`, and it stays untouched.

---

## Contract

```gdscript
NifServer.request(nif_path, owner, on_complete: Callable, prefer_static := false) -> void
NifServer.get_stats() -> Dictionary  ·  reset_stats()
NifServer.purge(nif_path, prefer_static := false)  ·  purge_all()
NifServer.canonical(nif_path) -> String   # static

await NifTreeBuilder.build(src: NifSource, apply_root_basis := true) -> Node3D
```

`NifServer` is the autoloaded entry point: it owns the archive read, the parse, the resolve queue,
the admission cap and the per-frame build budget. `NifTreeBuilder` is the construction half and is
called directly only by code that already holds a `NifSource`.

**Delivery is a callback, not an await, and that is the leak guarantee.** `on_complete` must be a
method on `owner` — not a closure capturing it, which the server rejects — so the server can tell
whether anyone is still there to receive the result. An owner that goes away before the build starts
gets no tree built at all; one that goes away during the build has the result freed rather than
orphaned.

**Delivered trees share their resources, and callers must not mutate them.** A built tree is cached
as a template keyed on §10's `(path, flatten)` identity and every delivery is a `duplicate()` of it.
`duplicate()` assigns object-typed properties by reference, so all instances of one model share one
mesh, material, shape, skin and `Animation`. That is the point — Godot coalesces a draw on RID
identity, so fifty placements become one instanced draw — but it means **setting a material property
on a delivered node changes every other instance of that model**. A caller needing per-instance
appearance must duplicate the resource itself first, accepting that it leaves the batch.

**The copy is synchronous, and one heavy model can still exceed a frame.**
`builds_per_frame_budget` caps builds *started*, pacing worker and TextureServer pressure;
`build_time_budget_usec` caps the wall clock one frame's drain may spend, which is what a cache hit
actually consumes. At least one item is always processed, so a copy costlier than the whole budget
still makes progress rather than wedging the queue — and therefore still blows the frame.

**Why not simply build per instance.** `build()` has one `await`, for textures; after it the whole
tree is assembled synchronously. A warm build is a single-frame cost, so the stall is not something
the cache introduced — it is something the cache reduces:

| model | nodes | build | duplicate | flattened |
|---|---:|---:|---:|---:|
| `dlc04mansionwindows01.nif` | 2,516 | 244.7 ms | 20.5 ms | won't flatten (`AnimationPlayer`) |
| `meshes/scol/villatest.nif` | 2,111 | 34.4 ms | 13.0 ms | **711 nodes, 4.8 ms** |
| `nvlucky38reactor.nif` | 258 | 14.4 ms | 2.4 ms | won't flatten (`AnimationPlayer`) |

**`prefer_static` is what brings a heavy model inside a frame**, because node count is what a copy
pays for. An SCOL flattened is 4.8 ms; the same SCOL hierarchical is 13.0 ms plus the caller's
`add_child`. The two that cannot flatten are singular set pieces rather than bulk placements.

**Copying on a worker thread was built, measured, and rejected.** It worked and it was faster —
copies taken on `WorkerThreadPool` while the main thread kept rendering came back structurally and
resource-identical to a main-thread copy, and the worst frame fell from 14.4 ms to 8.3 ms — but
every configuration aborted the process during engine shutdown, while the synchronous version exits
cleanly. Do not re-attempt it without reading `Plans/NifServer/Implementation/outstanding_issues.md`
#11 first.

**There is no eviction policy.** Templates stay resident until `purge()`/`purge_all()`, and a
resident template pins its textures too — `TextureServer.purge()` frees nothing while a reference is
held. `get_stats()` reports `resident_tree_count` and `resident_tree_node_count` so a caller can
watch residency; acting on it is not yet automatic.

**`prefer_static` is a preference, not an override.** It asks for §10's flattened form — one wrapper
with one `MeshInstance3D` per mesh, hierarchy removed, nothing merged. A file with dynamic content
comes back hierarchical instead, because flattening it would discard the behaviour that makes it
work. The root always carries `nif_flattened`, and when that is false
`nif_not_flattened_because` names the blocker, so the decision is reported rather than silent. A
caller placing scenery does not know whether a given SCOL animates, and should not have to.

On success ownership transfers to the caller, which must parent or free it. A result still
unparented **one full frame later** is freed by the safety net — a full frame, not a deferred call,
so a caller that parents on the next frame is not freed underneath it.

**Honest return.** What the file contains is what comes back. Nothing is invented to make a result
more convenient, and nothing is withheld because a caller might not want it. If a return needs
merging with another — a body part onto a skeleton, a weapon onto a hand — that is the caller's
work, and NifServer offers no entry point for it.

| the file has | the return has |
|---|---|
| declared bones forming a hierarchy inside it | a `Skeleton3D`, skins bound to it |
| declared bones as a flat list | unresolved named binds, no `Skeleton3D` |
| sequences addressing nodes in this file | an `AnimationPlayer` with those clips bound |
| sequences addressing a rig composed elsewhere | the names in `nif_unbound_sequences` metadata |
| collision | one body per owning node, parented under that node |
| `bhkBlendCollisionObject` bones | `PhysicalBone3D` under an inert `PhysicalBoneSimulator3D` |
| `NiBillboardNode` | a `NifBillboardNode` that orients itself, not material state |
| a node type Godot has no equivalent for | a `Node3D` with its block type in metadata |

**Already converted.** Positions are metres, the tree is Y-up and Godot-forward, triangle winding is
Godot's. No consumer applies an axis correction, a unit scale or a winding flip afterwards.
`apply_root_basis := false` exists for a caller that has already oriented its own parent.

**`build()` is a coroutine — await it.** It warms every texture the file references as one batch,
awaits `TextureServer.request()` for each, and then builds the tree in a single synchronous pass from
an already-resident set. That is the whole of TextureServer's external surface: `warm()` and
`request()`. Node construction itself never awaits.

**Names are reversible.** Authored NIF names survive Godot's node-name restrictions through
`nif_names.gd`, and the authored form is always on the node as `nif_name` metadata.

**Synchronous, main thread.** `build()` does the whole job in one call on the calling thread, and
callers run it on the main one. This is a statement of what is built, not a constraint that has been
established: the queue, frame budget and worker split of
[`nif_server_v2.md`](../../../../Plans/NifServer/nif_server_v2.md) section 4 are Stage E and do not
exist yet, and section 4's own rationale for the split is itself unverified — see
[`outstanding_issues.md`](../../../../Plans/NifServer/Implementation/outstanding_issues.md) #10.

`NifSource.load()` and `ArchiveServer.read()` are pure and take no locks, so both are safe to call
from a worker today.

**The returned tree is not parented.** `build()` hands back a root that is outside the active scene
tree; the caller attaches it, deferred. Godot's own thread-safety documentation allows building
node arrangements outside the active tree, and keeping the return unattached is also what lets the
caller decide placement, avoids `is_inside_tree()` dependencies such as `global_transform`, and
stops `_enter_tree`/`_ready` firing part-way through construction.

---

## Files

| | |
|---|---|
| `nif_server.gd` | The autoload: queue, admission, budgets, document and tree caches. |
| `nif_tree_builder.gd` | The builder. `build()` is the whole public surface. |
| `nif_billboard_node.gd` | Per-frame billboard orientation for `NiBillboardNode`. |
| `nif_names.gd` | Reversible NIF-name ↔ node-name escaping. |
| `previews/` | Generated scenes for visual inspection. Written by the test, not by hand. |

`NifSource` is a native class registered from `native/src/nif/`; it exposes nifly's object model
without flattening or interpreting it.

---

## Tests

`project/tests/servers/test_nif_source.gd` — the native reader, gated on the whole corpus parsing.
`project/tests/servers/test_nif_tree_builder.gd` — the tree, and it regenerates `previews/`.
`project/tests/servers/test_nif_server.gd` — the contract: delivery, budgets, the tree cache.
`project/tests/servers/test_nif_duplicate_bench.gd` — timing measurement, skipped by the runner.

Both must print `ALL CHECKS PASSED` and exit `0` before a change here is done.

```
cd project
../tools/Godot_v4.7.1-stable_linux.x86_64 --headless --path . tests/servers/test_nif_source.tscn
../tools/Godot_v4.7.1-stable_linux.x86_64 --headless --path . tests/servers/test_nif_tree_builder.tscn
```

Known gaps are recorded in
[`Plans/NifServer/Implementation/outstanding_issues.md`](../../../../Plans/NifServer/Implementation/outstanding_issues.md),
not left implicit.
