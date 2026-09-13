# Server Stack: Outstanding Issues

Open items from Stages A–D of [`server_stack_build_order.md`](../../server_stack_build_order.md).
Each is either a known gap in what was built or a decision not yet made.

**Severity:** `BLOCKER` = a stated spec section cannot be met · `GAP` = incomplete, non-blocking ·
`DECISION` = works, but a choice is deferred

---

| # | Issue | Severity |
|---|---|---|
| [1](#1-nifly-nistringpalette-truncation) | nifly `NiStringPalette` truncation | `FIXED` |
| [2](#2-morph-controller-traversal-incomplete) | Morph controller traversal incomplete | `FIXED` |
| [3](#3-collision-transform-shapes-extracted-not-applied) | Collision transform shapes extracted, not applied | `DECISION` |
| [4](#4-text-keys-reachable-from-only-one-link) | Text keys reachable from only one link | `FIXED` |
| [5](#5-property-tracks-not-bound) | Property tracks not bound | `GAP` |
| [6](#6-sequences-addressing-an-external-rig-stay-unbound) | Sequences addressing an external rig stay unbound | `DECISION` |
| [7](#7-texture-eviction-policy) | Texture eviction policy | `DECISION` |
| [8](#8-windows-positional-read-unverified) | Windows positional read unverified | `DECISION` |
| [9](#9-loose-files-not-supported) | Loose files not supported | `DECISION` |
| [10](#10-4s-threading-rationale-does-not-hold-for-godot-472) | §4's threading rationale does not hold for Godot 4.7.2 | `FIXED` |
| [11](#11-nifserver-does-not-cache) | NifServer does not cache | `FIXED` |
| [12](#12-collision-alignment) | Collision alignment | `PARKED` |

---

## 1. nifly `NiStringPalette` truncation

`FIXED` — carried as a local patch against the nifly submodule.

`NiString::Read()` ended with `str = buf.get()`, a `char*` assignment that stops at the first
embedded NUL. A string palette is NUL-*separated*, so a 1,107-byte palette loaded as 5 bytes and
360 controlled blocks across 5 files resolved to nothing. All five are player idles in
`Fallout - Meshes.bsa`: `eatidle.kf`, `pistolvariant01.kf`, `talk_handsatside_moving.kf`,
`talk_handsatside_moving2.kf`, `talk_handsatside_still2.kf`.

`native/nifly_patches/0001-nistring-read-preserve-embedded-nuls.patch` tracks the byte count each
size branch read and assigns `str.assign(buf.get(), sizeRead)`. nifly is a submodule pinned to
upstream, so the fix cannot be committed into the checkout; `native/SConstruct` applies the patch
before globbing nifly's sources, so a fresh clone or a `git submodule update` still builds patched.
Application is idempotent, and a patch that neither applies nor reverse-applies stops the build
rather than silently producing a library that reads NIFs wrong. See
[`native/nifly_patches/README.md`](../../../native/nifly_patches/README.md).

All 365 palette-addressed links across the five files now resolve. `test_nif_source` D6 asserts
this per file and fails if the patch is ever dropped from the build.

The resolved names are verified correct rather than merely non-empty: 50 of the 73 targets in each
file match a node in `meshes/characters/_male/skeleton.nif` exactly, which misaligned offsets could
not produce.

**The remaining 23 targets per file name bones the New Vegas male skeleton does not have** —
`Bip01 L Finger0`/`01`/`02`, `Bip01 L ForearmTwist`, `Bip01 L UpperArmTwist`, `Torch`. Those are
Fallout 3-era names; New Vegas uses `Bip01 L Thumb1`, `Bip01 L ForeTwist`, `Bip01 LUpArmTwistBone`.
Of 2,109 `meshes/characters/_male/*.kf` files, exactly these five carry them, so they are FO3 assets
shipped unused. Roughly a third of their tracks will bind to nothing whatever the caller does. That
is the asset, not the reader — do not chase it as a defect.

Unmatched targets are ordinary in any case: 647 of those 2,109 files address `##Cover`, `##Trigger`,
`##Shells` and similar weapon-part bones carried by the weapon's own NIF, which is the composed-rig
case [#6](#6-sequences-addressing-an-external-rig-stay-unbound) covers.

All five are single `SpecialIdle*` sequences carrying only `NiTransformController`. Binding stays
caller-side per #6; nothing consumes them yet.

Inert elsewhere: every other NIF string is read at its exact length with no embedded NUL, so
assigning by length yields the same bytes. SHA-256 over all 140,475 node names in the corpus is
identical with and without it.

Reported upstream as [ousnius/nifly#66](https://github.com/ousnius/nifly/issues/66). Drop the patch
and this entry once that lands and the submodule is advanced.

## 2. Morph controller traversal incomplete

`FIXED`

`NiGeomMorpherController` was looked for on `NiAVObject::controllerRef` directly. Controllers chain
through `nextControllerRef`, so a morpher that was not first was missed.

`nif_source.cpp` now walks the chain, guarded at 64 links. `skeleton.nif` yields 31 morph frames on
`HeadAnims:0` — the FaceGen expression set (`Base`, `BlinkLeft`/`Right`, `LookUp`/`Down`/`Left`/
`Right`, the `Aah`/`BMP`/`FV`/`W`/`Oh` phonemes, `Anger`/`Fear`/`Sad`/`Happy`) — where it previously
yielded none. Asserted in `test_nif_source` D10.

## 3. Collision transform shapes extracted, not applied

`DECISION` — the transform is now reported. Applying it measurably makes placement worse.

`bhkTransformShape` and `bhkConvexTransformShape` wrap a shape to place it. `collect_shapes()`
recursed through them to reach the leaf and discarded the transform. It now accumulates down the
recursion and reports it per shape as `has_transform` + a row-major 4x4 with translation in metres.

**`nif_tree_builder.gd` deliberately does not apply it**, on measurement. Comparing the union of
every collision shape against the union of every render mesh, per file:

| | files |
|---|---:|
| carry a wrapper transform | 51 (145 shapes) |
| applying it improves AABB agreement | 3 |
| applying it worsens it | **11** |
| no measurable change | 24 |

The raw reading matches the render mesh closely and the wrapped one does not:

| file | mesh | collision raw | collision wrapped |
|---|---|---|---|
| `usonianhomedamm02.nif` | 3.26, 2.31, 3.78 | **3.16, 2.31, 3.78** | 0.45, 0.33, 0.54 |
| `nv_noso_neonsign05a.nif` | 5.18, 0.63, 5.33 | **5.16, 0.55, 5.31** | 0.74, 0.18, 1.32 |
| `pedwalkstrip.nif` | 40.17, 11.21, 13.96 | **38.94, 11.16, 13.98** | 5.56, 1.59, 2.00 |

Agreement to within 1–3% on all three axes is not coincidence: the leaf shape is already in correct
metres and the wrapper's `1/7` applies it a second time.

The scale content is exactly two values: 119 shapes at `1.0` and 26 at `0.143`. That second figure is
`1/7`, which is `kGamebryoUnitsToMeters / kHavokToMeters` — so the wrapper is carrying a unit
conversion the shape data has already had applied. What it converts *between* is not established, and
the obvious reading (leaf vertices are in Gamebryo units and need the extra `/7`) is contradicted by
the raw shape already matching the mesh.

The extraction itself is verified: the layout assumption is confirmed against nifly's own
`Matrix4::Translate`, which writes `m[3]`, `m[7]`, `m[11]`. Every wrapper in the corpus carries
rotation and/or scale and **never** a translation, so the metre conversion on those indices is
untested by real data.

45 shapes carry a real rotation. Whether those should be applied is not settled either — the AABB
metric above compares extents and is close to rotation-invariant, so it cannot distinguish them.
A better test would compare oriented hulls, not AABBs.

`previews/usonianhomedamm02.tscn` carries both readings in one scene for visual comparison: the
ordinary `Collision` node as the builder produces it, and a `CollisionWithWrapperApplied` node
holding the same shapes with the transform applied.

**Settled by the original game.** Base `0x0015CDF2` spawned in Fallout New Vegas with collision
debug rendering shows the authored collision at the same scale as the render mesh. The 1/7 is not to
be applied. NifSkope renders it scaled and is wrong. See issue #12 for the separate question of
where the collision sits.

The 45 rotation-carrying shapes are still unverified — the AABB metric used above is close to
rotation-invariant and cannot judge them.

## 4. Text keys reachable from only one link

`FIXED`

`NiTextKeyExtraData` was read only through `NiObjectNET::extraDataRefs`, which finds node-attached
blocks. Most hang off `NiControllerSequence::textKeyRef`, a separate link.

`Sequence` now carries `text_keys`, read from that ref — where animation events belong anyway.
Corpus-wide **7,212 sequences carry text keys, 29,574 keys total**, against 263 blocks reachable
before. `barracksdoor.nif`'s `Open` reads `0.00s 'start'`, `1.67s 'end'`. Asserted in
`test_nif_source` D10.

## 5. Property tracks not bound

`GAP` — transform curves are extracted and played; property curves are extracted and left.
**271 files return an AnimationPlayer with no tracks at all.**

`get_sequences()` returns each `ControllerLink`'s interpolator with its key data:
`NiTransformInterpolator`, the B-spline transform pair (sampled — cubic control points have no
keyframe equivalent), `NiFloatInterpolator`, `NiBoolInterpolator` and `NiPoint3Interpolator`.
`NiBlend*` reports `kind == "blend"` and carries no keys, which is what it is.

`nif_tree_builder.gd` builds `AnimationPlayer` tracks from the **transform** kind only. Measured
across the shipped `.nif` corpus:

| | |
|---|---:|
| files with sequences | 1,153 |
| …with at least one property-targeted link | **582** |
| …**property-only**, so the emitted AnimationPlayer is empty | **271** |
| links: transform / property | 25,717 / 5,295 |

`meshes/nvdlc04/dungeons/utemple/nvdlc04uskydome.nif` is the shape of the failure: a 266-second
looping `Idle` whose three controlled blocks are two scrolling UV transforms and a `SELF_ILLUM`
colour curve, and not one transform track. The sky is static.

Exactly **11** distinct `(propType, ctrlType, ctrlID)` triples exist corpus-wide — a closed,
hand-writable mapping table, corroborating nif_server_v2.md §7.3's independent count:

| triple | links | Godot |
|---|---:|---|
| `NiMaterialProperty / NiMaterialColorController / SELF_ILLUM` | 1218 | `emission` |
| `NiMaterialProperty / NiAlphaController` | 1182 | `albedo_color.a` |
| `NiMaterialProperty / BSMaterialEmittanceMultController` | 879 | `emission_energy_multiplier` |
| `NiTexturingProperty / NiTextureTransformController / 0-0-TT_TRANSLATE_U` | 704 | `uv1_offset.x` |
| `NiTexturingProperty / NiTextureTransformController / 0-0-TT_TRANSLATE_V` | 672 | `uv1_offset.y` |
| `NiTexturingProperty / NiTextureTransformController / 0-0-TT_SCALE_U` | 177 | `uv1_scale.x` |
| `NiTexturingProperty / NiTextureTransformController / 0-0-TT_SCALE_V` | 153 | `uv1_scale.y` |
| `BSShaderPPLightingProperty / BSRefractionStrengthController` | 106 | ~`refraction` |
| `NiTexturingProperty / NiTextureTransformController / 0-0-TT_ROTATE` | 105 | **none** |
| `BSShaderPPLightingProperty / BSRefractionFirePeriodController` | 57 | **none** |
| `NiMaterialProperty / NiMaterialColorController / SPEC` | 42 | specular |

Two have no `StandardMaterial3D` equivalent and force a custom shader regardless of anything else.

**Two things have to be settled before this can be implemented, and they are not track-plumbing.**

Property blocks are shared: ~34% of `NiMaterialProperty` are referenced by two or more nodes, while
shader properties never are. A Godot material fuses blocks whose sharing granularity differs, so one
property track has to fan out to every node that referenced the same block. `SceneNode` already
carries `property_block_indices` so a consumer can do it; nothing does it yet.

An `AnimationPlayer` track pointed at a material is **in-place mutation, every frame**. Implementing
this creates the shared-material hazard across 582 files, which is the caching question, not an
animation one — see `project/GodotBryo/Servers/MaterialServer/README.md`. Deciding the track target
(a shared material, a per-instance material, or an instance uniform) decides whether those files can
batch.

## 6. Sequences addressing an external rig stay unbound

`DECISION` — the self-contained/external split, mirroring the skeleton rule.

An `AnimationPlayer` is emitted when a sequence's targets are nodes in the same file — doors, lifts,
terminals, anything with its own `NiControllerManager`. A KF addressing a rig composed from several
files resolves to nothing here, and the sequence name is recorded in `nif_unbound_sequences`
metadata rather than dropped. Retargeting belongs to whoever did the composing, the same reasoning
that has a flat-bone-list skin return named binds instead of a `Skeleton3D`.

Unsettled: whether NifServer should also offer the unbound clips as loose `Animation` resources for
the caller to retarget, instead of the caller re-reading the KF through `NifSource` itself.

## 7. Texture eviction policy

`DECISION` — V1 is resident-forever; `purge()`/`purge_all()` exist as manual eviction only.

Measured: 26,840 textures, 4.26 GB of DDS bytes, 4.88 GB peak process memory with everything
resident. It fits on a dev machine; it is not free on a 4–6 GB GPU alongside the game.

Two constraints on any policy, both measured:

- **Byte budget, not count** — mean texture 166 KB, largest 10.7 MB, a 64× spread.
- **Eviction must respect holders** — `ImageTexture` is refcounted, so purging while a material holds
  it frees nothing and the next `request()` decodes a *second* copy. Demonstrated directly. A naive
  eviction pass can therefore increase memory.

LRU under a byte watermark fits both. See [`texture_server.md`](../../TextureServer/texture_server.md).

## 8. Windows positional read unverified

`DECISION` — code exists, no host to run it on.

`positional_read.cpp` implements both `pread()` (POSIX) and `ReadFile` + `OVERLAPPED` (Windows). Only
the POSIX path has been executed. The Windows path is written but untested.

## 9. Loose files not supported

`DECISION` — deliberate, carried over from the existing resolver.

ArchiveServer reads BSAs only. Loose-file participation and its precedence relative to archive
entries is deferred, not forgotten — adding it implicitly would silently change resolution for every
consumer.

## 10. §4's threading rationale does not hold for Godot 4.7.2

`FIXED` — §4 re-derived. The split is unchanged; its justification is replaced.

The old rationale claimed `RID_Owner<T>` locking is compiled out off the main thread. Checked against
`enginedocs/godot-4.7.2 source/`: `THREAD_SAFE` is a per-owner template argument, and `mesh_owner`,
`texture_owner`, `material_owner`, `shader_owner` and `skeleton_owner` all request it. The owners
that do not are renderer-internal per-instance bookkeeping. The old §4 also barred `_resolve()` from
touching any `Node`, which contradicts Godot's own documentation that building scene chunks outside
the active tree is fine.

§4 now rests on two things that are true:

- TextureServer's caches are main-thread-owned with no atomics by design, and `_build()` reads them
  for every texture slot. Moving `_build()` to a worker means making another server's internals
  thread-safe.
- Measured over a 60-model burst with textures resident, `_resolve()` is already the larger half:
  read 33.1 ms + parse 14.7 ms against build 21.4 ms. `_build()` is 0.36 ms per model, which a frame
  budget absorbs.

§4.2 also records that queue ordering must not be FIFO — `world_streamer.gd` learned that a plain
queue builds the far side of a cell first, and orders by real circular distance instead.

## 11. NifServer does not cache

`FIXED` — built trees are cached as templates and delivered as `duplicate()`.

`build()` holds no cache of any kind. A cell load asking for the same model 50 times gets 50
independent trees with 50 independent `ArrayMesh`, `StandardMaterial3D` and `Shape3D` instances.

This is a rendering problem, not just wasted work. Godot batches on **RID identity, not content**:
`render_forward_clustered.cpp` builds the draw-list sort key from `p_mesh.get_local_index()` and the
material's own index, and coalesces consecutive elements into one instanced draw only when the whole
key matches. Two byte-identical `ArrayMesh` objects are two RIDs, so 50 copies are 50 draw calls
where one shared mesh would be one instanced draw.

**The fix is cheap because `Node.duplicate()` shares resources.** Object-typed properties are
assigned by reference, not copied — `scene/main/node.cpp` duplicates a property's value only when it
carries `PROPERTY_USAGE_ALWAYS_DUPLICATE`, which engine-wide is used by seven things
(`VoxelGI.data`, `TextEdit.syntax_highlighter`, some Skeleton2D and TileSet internals) and by nothing
on `MeshInstance3D`, `CollisionShape3D`, `AnimationPlayer` or `Skeleton3D`. So a cached tree plus
`duplicate()` yields new nodes sharing the same mesh, material, shape, skin and animation RIDs —
exactly the condition the coalesce tests for.

Caching whole trees also dissolves the separate question of caching collision, skin and animation
resources: they are sub-resources of the cached tree.

**Measured.** `duplicate()` beats a warm `build()` on every shape tested, by 3-10x.
`project/tests/servers/test_nif_duplicate_bench.tscn` is the harness; it is a measurement, not a gate,
and the runner skips it. Godot 4.7.1, Linux, per instance at N=100:

| model | nodes | build | duplicate | |
|---|---:|---:|---:|---:|
| `milkbottle01` trivial prop | 5 | 0.107 ms | 0.036 ms | 2.9x |
| `barracks01` architecture | 15 | 1.590 ms | 0.151 ms | **10.6x** |
| `upperbody` skin, no hierarchy | 34 | 1.234 ms | 0.214 ms | 5.8x |
| `nvdlc01stealthsuit_go` skin + `Skeleton3D` | 10 | 0.405 ms | 0.109 ms | 3.7x |
| `vdoorslidingvault22` animated | 27 | 0.805 ms | 0.222 ms | 3.6x |

At N=1 the margin narrows to 2-6.7x; the ratio is stable from N=10 upward. The gain tracks material
and texture count rather than node count -- `barracks01` has 15 nodes and 10 materials and gains
most, `upperbody` has 34 nodes and 6 materials and gains less.

Timing is the smaller half. The bench also asserts the resource sharing the draw-call argument
depends on: a copy shares **every** mesh, material, shape and `Animation` with its template, and two
fresh `build()` calls share none. That is the RID identity the coalesce tests for, so 100 placements
become 1 instanced draw instead of 100.

**The skinned unknown is resolved.** A tree carrying its own `Skeleton3D` binds its skin through the
relative `NodePath` `../..`, and in a copy that resolves to the **copy's** `Skeleton3D`, not the
template's, while the `Skin` resource itself is shared. `BoneAttachment3D` bone indices are correct
once parented, and match the template exactly.

Two caveats found while measuring, neither blocking:

- Duplicating a tree containing `BoneAttachment3D` logs `Bone index -1 out of range` per attachment,
  because the attachment is copied before the copy's `Skeleton3D` has bones. Harmless -- the index
  resolves on entering the tree -- but the bench run emitted 336 of them, so at cell-load scale this
  is real log spam.
- Only 185 corpus files carry a bone hierarchy, and `meshes/characters/_male/upperbody.nif` is not
  one: it leaves `skeleton` unset by design (§9). A skinned model alone does not exercise the
  `NodePath` path; a file with both is needed, hence `nvdlc01stealthsuit_go.nif` above.

### Implemented

`nif_server.gd` holds `_trees`, keyed on §10's `(path, flatten)` identity. A template is never
delivered and never parented; callers receive `template.duplicate()`, including on the build that
created it. Two requests for one key can both miss, because the document cache deduplicates the
parse but each build spans frames — whichever finishes first becomes the template and the rest
deliver the tree they already built, rather than discarding work or replacing a template other
instances share.

`get_stats()` adds `resident_tree_count` and `resident_tree_node_count`; `purge(path, prefer_static)`
drops one template and `purge_all()` drops all, matching TextureServer's shape. Node count is the
residency figure because meshes and textures are shared — counting those would attribute the same
bytes to several caches. There is still no eviction policy, and a resident template pins its
textures, which is [#7](#7-texture-eviction-policy).

### The per-frame cost changed shape

A cache miss suspends at `build()`'s await and costs the frame almost nothing. A cache **hit**
duplicates synchronously, so `builds_per_frame_budget` — a count of builds started — stopped
bounding frame time. `build_time_budget_usec` (default 8,000) now caps the drain's wall clock. Both
apply, and whichever is reached first ends the drain.

`build()` never spread construction across frames: it has one `await`, for textures, after which the
tree is assembled synchronously. A warm build of `dlc04mansionwindows01.nif` is 244.7 ms in a single
frame, *per instance*. The cache makes that 20.5 ms. The stall is not new; it is reduced.

At least one item is always processed, so **one heavy model still exceeds a frame** — 16.5 ms worst
frame for a 2,111-node SCOL including the caller's `add_child`. `prefer_static` is the lever that
fixes it, because node count is what a copy pays for:

| model | nodes | build | duplicate | with `prefer_static` |
|---|---:|---:|---:|---|
| `dlc04mansionwindows01.nif` | 2,516 | 244.7 ms | 20.5 ms | won't flatten (`AnimationPlayer`) |
| `meshes/scol/villatest.nif` | 2,111 | 34.4 ms | 13.0 ms | **711 nodes, 4.8 ms** |
| `nvlucky38reactor.nif` | 258 | 14.4 ms | 2.4 ms | won't flatten (`AnimationPlayer`) |

### Threaded duplication: built, measured, rejected — NEEDS RETRY

Copying a template on a `WorkerThreadPool` task is correct and faster, and still cannot be used.

It worked: eight concurrent copies of 2,100- and 2,500-node trees, taken under Vulkan Forward+ with
the renderer running, were each structurally and resource-identical to a main-thread copy. Adding a
delivery pacer — worker completions bunch, and the callers' `add_child` then stacks inside one frame
— took the worst frame from 14.4 ms to 8.3 ms.

**But every configuration aborted the process during engine shutdown**, after `ALL CHECKS PASSED`,
with no error printed. Ruled out by bisection: it is not the shutdown cleanup (aborts with cleanup
removed entirely), not `call_deferred` from the worker (aborts with the handoff replaced by
main-thread polling), not task draining (aborts with and without `wait_for_task_completion`), and
not the new gates (aborts with all of them disabled). The synchronous version of the same cache
exits `0` repeatedly.

The core dump says what it is: **`SIGSEGV` inside `__pthread_mutex_lock`**, reached from Godot's
shutdown path, converted to `abort` by Godot's crash handler. Locking a mutex that has already been
freed — a use-after-free of a mutex-bearing object during teardown, not a cosmetic exit code and not
a failed assertion. 25 cores, one signature.

**This is a retry, not a dead end.** What is NOT established: whose bug it is. The Godot binary
carries no symbols, so the faulting function has no name, and "creating Nodes on a worker is not
viable in 4.7.1" is a hypothesis, not a finding. The copies themselves verify correct every time.

To retry, in rough order of cost:

1. Symbolise the crash. A Godot build with symbols, or a debug build, names the function in one
   run and probably settles it outright.
2. Establish whether it reproduces without NifServer at all — a bare scene that duplicates any
   node tree on a `WorkerThreadPool` task and quits. If it does, it is an engine-level constraint
   and belongs upstream; if it does not, it is ours.
3. Check whether the tree's contents matter. `MeshInstance3D` takes a RenderingServer instance RID
   in its constructor, so a copy containing no `VisualInstance3D` is the obvious control.

The frame-cost prize is real — 14.4 ms to 8.3 ms worst frame, and it is the only approach measured
that brings an un-flattened heavy SCOL inside a frame — so this is worth returning to once there is
a symbolised stack.

Note that the project has a *separate* pre-existing shutdown abort: `EsmServer` starts a `Thread` in
`_ready()` and only calls `wait_to_finish()` from `_process` once it is no longer alive, so any
scene quitting early destroys a running `Thread`. A scene that awaits one frame and quits aborts on
`master`. That is the source of the `134` exits across the terrain, BSA and tri gates, and it is not
the threaded-duplication abort above — which reproduces in long-running scenes where the ESM thread
has long since finished.

### Not needed yet: chunking a copy across frames

Measured in case the frame cost has to come down further. Every tree is a thin spine that fans out
at a shallow depth — `villatest` is 2 spine nodes then 709 subtrees of ~3 nodes, and
`dlc04mansionwindows01` is 3 then 45 subtrees of 57 — so a copy can be sliced by hand-copying the
spine and `duplicate()`ing the fan-out in budgeted slices. Recorded, not built.

### Still undecided, and not a performance question

An `AnimationPlayer` property track pointed at a shared material is in-place mutation every frame,
and sharing is exactly what makes this fast. Implementing
[#5](#5-property-tracks-not-bound) now would mutate every instance of a model together. That is #5's
question and MaterialServer's, not this one's — the cache makes it sharper, not different.

**Not applicable to FaceGen.** Per-NPC morph deformation means a unique mesh by definition.

A separate MeshServer was considered and declined for now — see
`project/GodotBryo/Servers/MeshServer/README.md`. MaterialServer is the stronger
case and is recorded alongside it in
`project/GodotBryo/Servers/MaterialServer/README.md`.

## 12. Collision alignment

`PARKED` — cannot be validated with the tools that exist today.

Collision alignment in the previous renderer took sustained tweaking, and it was driven **empirically
by walking the map** and finding things that were wrong — the fridges being the memorable case.
Static comparison is a poor substitute: an AABB metric cannot tell legitimate hull simplification
from a real offset, and inferring the placement rule from geometry alone does not work — it was
tried several ways here and each answer failed against the next file. NifServer cannot yet be driven
over the world, so the feedback loop that actually solved this last time is not available. Parked
until it is.

Everything below is current and verified. Do not act on part of it without reading the ruled-out
list.

A collision object is attached to a node, and `_build_collision()` parents its body under that
node — so the owning node's transform chain places it. For `usonianhomedamm02.nif` the collision
object is on the root `BSFadeNode`, whose transform is identity, while the three `NiTriStrips`
carrying the geometry each hold a translation of `(-582.197, -70.309, 0)` raw. The meshes move, the
collision does not.

Measured in the built tree:

| file | mesh ↔ collision offset |
|---|---|
| `usonianhomedamm02.nif` | (-8.310, -1.005, 0.003) m — exactly the node translation |
| `ramshacklebusdoor02.nif` | (-2.056, 0.115, 1.350) m |
| `barracks01.nif` | (0.000, 0.017, -0.007) m — its geometry nodes carry no translation |

**The collision data is authored in the same space as the untransformed mesh vertices.** Before any
node transform, the two unions sit in the same place to within 7 mm:

```
mesh      vertex centre = (8.319, 1.155, 1.890) m
collision vertex centre = (8.312, 1.155, 1.888) m
```

That also confirms the unit handling: 582.3 Gamebryo / 83.12 Havok = 7.005, so each converts to the
same metres by its own factor, and the `bhkTransformShape` 1/7 of issue #3 is redundant rather than
load-bearing.

Corpus census, comparing the mesh union with node transforms applied against the collision union
without them — i.e. exactly what the builder produces — across the 10,162 files carrying both:

| centre offset | files |
|---|---:|
| < 0.1 m | 5,617 |
| 0.1–1 m | 2,945 |
| 1–5 m | 1,004 |
| > 5 m | 596 |

**These numbers measure disagreement and must not be read as a defect count.** `boxcarwall02.nif`
sits in the 0.1–1 m bucket at 0.84 m and is *correct* — a simplified hull does not share a centre
with its render mesh. The proven legacy path handles that file, and our output for it is fine. Only
the far tail is suspicious, and even there the cause is unestablished.

### The defect

`usonianhomedamm02.nif` and `ramshacklebusdoor02.nif` both carry a plain `bhkRigidBody` whose
translation is exactly zero, so the offset comes entirely from the geometry nodes' own translations,
which collision never receives. nifly supplies node transforms, body transforms and shape vertices
correctly; this is policy in `nif_source.cpp` / `nif_tree_builder.gd`, not a parsing problem.

### Ground truth: Fallout New Vegas itself

Base `0x0015CDF2` spawned in the original game with collision debug rendering shows the authored
collision **co-located with the render mesh and at the same scale**. That is the reference, and it
settles two things:

- The `bhkTransformShape` 1/7 must **not** be applied — issue #3's conclusion, confirmed. NifSkope
  renders it scaled and is simply wrong here.
- The 8.3 m separation NifServer produces is **ours**. Issue #12(a) is a real defect.

Supporting facts, verified but not conclusions in themselves: both readers agree exactly on node
transforms (legacy reports `UsonianDamM02_Trim:0 origin = (-8.317094, -1.004414, 0)`, matching
`-582.197 / 70`), and `NifReader.get_collision_shapes()` returns zero shapes for this file because
its `unwrap_shape()` handles only `bhkMoppBvTreeShape`. So the shipping path never extracted this
collision at all, and cannot be used as a comparison case — but the original game can, and did.

### The rule the shipping loader uses

```cpp
flatten_transform(flatten_via_scene_nodes(av, ...).ComposeTransforms(rigid_body_transform(body)), cs);
```

Collision receives the **collision-bearing AV node's** transform-to-root, composed with the body
transform for `bhkRigidBodyT` only.

For this file that AV is the root block and its own transform is never composed in, so that rule
alone does not close the 8.3 m gap. Since the original game clearly does close it, the offset comes
from somewhere this has not yet read. Unread candidates on the blocks involved include
`bhkCollisionObject`'s own target pointer, `bhkPackedNiTriStripsShape::scaling`, and
`hkSubPartData`. **Open, and not to be guessed at.**

### What is ruled out

- `NiCollisionObject::targetRef` — checked, points at the same root block that `collisionRef` reached.
  No hidden owning node. (Now extracted and exposed as `collision_target_block_index` regardless.)
- **A plain `bhkRigidBody`'s transform.** Correctly skipped, and it must stay skipped.
  `meshes/vehicles/vertibirdencount01.nif` has six of them carrying real translations around −50 m
  in Z with real rotations, which looks like recoverable placement data and is not.
  `nif_loader.cpp`, proven in play, documents why:

  > A PLAIN `bhkRigidBody` (not "T") must NOT have this applied, even though nifly parses the exact
  > same translation/rotation fields for it — those values are Bethesda's own re-expression of the
  > SAME offset the AV's node chain already carries (in Havok's unit scale), not an additional delta.

  Applying them double-counts.
- The `bhkTransformShape` 1/7 as the fix — applying it lands the shape at 1.19 m, not the 0 m the
  geometry occupies.

### The one distinguishing feature found

`usonianhomedamm02.nif` reaches its collision through `bhkTransformShape`; `boxcarwall02.nif` reaches
its through `bhkMoppBvTreeShape`. Legacy's `unwrap_shape()` handles only Mopp, so the shipping path
never extracted a transform-wrapped shape at all — this is unexplored territory, not a regression.
51 files are in that class, which cannot by itself account for the 596-file tail.

**Why this was missed:** the alignment check added for issue #3 compared AABB *sizes* only, never
centres, so a pure translation error was invisible to it. Found by inspecting
`usonianhomedamm02.nif` in NifSkope against the generated preview scene.
