# Server Stack: Outstanding Issues

Open items from Stages A–D of [`server_stack_build_order.md`](../../server_stack_build_order.md).
Each is either a known gap in what was built or a decision not yet made.

**Severity:** `BLOCKER` = a stated spec section cannot be met · `GAP` = incomplete, non-blocking ·
`DECISION` = works, but a choice is deferred

---

| # | Issue | Severity |
|---|---|---|
| [1](#1-nifly-nistringpalette-truncation) | nifly `NiStringPalette` truncation | `BLOCKER` |
| [2](#2-morph-controller-traversal-incomplete) | Morph controller traversal incomplete | `GAP` |
| [3](#3-collision-transform-shapes-discarded) | Collision transform shapes discarded | `GAP` |
| [4](#4-text-keys-reachable-from-only-one-link) | Text keys reachable from only one link | `GAP` |
| [5](#5-property-tracks-not-bound) | Property tracks not bound | `GAP` |
| [6](#6-sequences-addressing-an-external-rig-stay-unbound) | Sequences addressing an external rig stay unbound | `DECISION` |
| [7](#7-texture-eviction-policy) | Texture eviction policy | `DECISION` |
| [8](#8-windows-positional-read-unverified) | Windows positional read unverified | `DECISION` |
| [9](#9-loose-files-not-supported) | Loose files not supported | `DECISION` |
| [10](#10-4s-threading-rationale-does-not-hold-for-godot-472) | §4's threading rationale does not hold for Godot 4.7.2 | `DECISION` |

---

## 1. nifly `NiStringPalette` truncation

`BLOCKER` — nif_server_v2.md §7.4 cannot be met while nifly is unpatched.

`NiString::Read()` ends with `str = buf.get()`, a `char*` assignment that stops at the first embedded
NUL. A string palette is NUL-*separated*, so a 1,107-byte palette loads as 5 bytes.

**Effect:** 360 controlled blocks across 5 files resolve to nothing. All five are player idles in
`Fallout - Meshes.bsa`: `eatidle.kf`, `pistolvariant01.kf`, `talk_handsatside_moving.kf`,
`talk_handsatside_moving2.kf`, `talk_handsatside_still2.kf`.

**Status:** reported upstream. Repro and issue text in [`tools/nifly_bug_repro/`](../../../tools/nifly_bug_repro/).

**Local patch is verified but NOT applied.** `str.assign(buf.get(), size_read)` takes those 360 links
to 0 and is provably inert elsewhere — SHA-256 over all 140,475 node names is byte-identical with and
without it. Carrying it locally is an open decision: it creates a merge burden against upstream, and
without it §7.4 stays unmet regardless of upstream turnaround.

## 2. Morph controller traversal incomplete

`GAP` — morph frames are extracted correctly but often not found.

`NiGeomMorpherController` is looked for on `NiAVObject::controllerRef` directly. Controllers form a
chain via `nextControllerRef`, so a morpher that is not first is missed. `skeleton.nif` contains
`NiGeomMorpherController` + `NiMorphData` and yields nothing.

**Fix:** walk the controller chain rather than checking the head. Extraction itself is unchanged.

## 3. Collision transform shapes discarded

`GAP` — affects 81 files.

`collect_shapes()` recurses through `bhkTransformShape` and `bhkConvexTransformShape` to reach the
leaf, but discards the transform those wrappers carry, so their shapes land at the wrong offset.
`bhkTransformShape` appears in 47 files, `bhkConvexTransformShape` in 34. The 11,134 ordinary
collision files are unaffected.

**Fix:** accumulate the transform down the recursion and store it per shape.

## 4. Text keys reachable from only one link

`GAP` — 263 of 7,745 blocks currently reachable.

`NiTextKeyExtraData` is read through `NiObjectNET::extraDataRefs`, which finds only node-attached
ones. The rest hang off `NiControllerSequence::textKeyRef`, a different link that is not yet walked.
Nothing is mis-parsed; the traversal is narrow.

**Fix:** expose `textKeyRef` alongside the sequence, where animation events belong anyway.

## 5. Property tracks not bound

`GAP` — transform curves are extracted and played; property curves are extracted and left.

`get_sequences()` now returns each `ControllerLink`'s interpolator with its key data:
`NiTransformInterpolator`, the B-spline transform pair (sampled — cubic control points have no
keyframe equivalent), `NiFloatInterpolator`, `NiBoolInterpolator` and `NiPoint3Interpolator`.
`NiBlend*` reports `kind == "blend"` and carries no keys, which is what it is.

`nif_tree_builder.gd` builds `AnimationPlayer` tracks from the **transform** kind only. Float, bool
and point3 links address a *property block* on a node, and §7.3's addressing problem is unsettled:
~34% of `NiMaterialProperty` blocks are shared between two or more nodes, so one property track has
to fan out to every node that referenced the same block, and a Godot `StandardMaterial3D` fuses
properties whose sharing granularity differs. The keys reach the caller; the binding does not.

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

LRU under a byte watermark fits both. See [`texture_server.md`](../../texture_server.md).

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

`DECISION` — the split may still be right; the stated reason for it is not.

`nif_server_v2.md` §4 pins `_build()` to the main thread and bars `_resolve()` from touching **any**
`Node`, on this rationale:

> The split exists because `RID_Owner<T>` locking is compiled out off the main thread with the
> Separate Rendering Thread model off.

Both halves fail a check against `enginedocs/godot-4.7.2 source/`.

**`THREAD_SAFE` is a per-owner template argument, not a global gated on the rendering thread model.**
The owners behind the types §4 names request it:

| owner | `THREAD_SAFE` |
|---|---|
| `RID_Owner<Mesh, true> mesh_owner` | true |
| `RID_Owner<Texture, true> texture_owner` | true |
| `RID_Owner<Material, true> material_owner` | true |
| `RID_Owner<Shader, true> shader_owner` | true |
| `RID_Owner<Skeleton, true> skeleton_owner` | true |
| `MeshInstance`, `LightInstance`, `RenderTarget`, `ShadowAtlas`, … | false |

The unsafe owners are the renderer's own per-instance bookkeeping, which script never addresses
directly.

**Barring `Node` construction off the main thread contradicts Godot's documentation**, which states
that creating scene chunks in tree arrangement outside the active tree is fine, and that the
resulting chunk is then added on the main thread via `call_deferred`.

**Provenance.** §4 inherits this from `nif_server_v1.md`, which attributes it to the top-of-file
comment in `project/gamebryo/mesh_resolver.gd`, which cites `phases/2/10-threaded-streaming-workers.md`
— prototype-era work. The crash it records ("Attempting to initialize the wrong RID") was real; the
mechanism recorded for it does not match this engine version.

**What is still true**, and is the real constraint on Stage E: Godot's documentation warns that
creating scene chunks from *multiple* threads risks resources being tweaked by several at once,
because a resource is loaded only once. NifServer shares resources heavily — one `ImageTexture` out
of TextureServer's cache is referenced by many materials — so one loader thread is the sanctioned
pattern and N concurrent `build()` calls is the case the warning is about. That is a cache-sharing
question, not a RID one.

**Open:** re-derive §4 against this engine version before Stage E is built, rather than
implementing the split as written.
