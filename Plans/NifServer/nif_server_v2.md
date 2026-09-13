# NifServer v2

Supersedes [v1](nif_server_v1.md). Same goal, same two-stage shape; the contract surface is now the
one settled in [the v1 tracker](nif_server_v1_tracker.md), and every scope decision is measured
against the shipped corpus in [Research](Research/nifserver_design_findings.md) rather than inferred
from the format.

**Status legend:** `SETTLED` = decided · `OPEN` = undecided

| | |
|---|---|
| **built standalone** | not an in-place edit of `mesh_resolver.gd`'s 6 construction paths |
| **companions** | [Texture Server](../TextureServer/texture_server.md) · [Archive Server](../ArchiveServer/archive_server.md) · [Research findings](Research/nifserver_design_findings.md) |

---

## Index

| # | Area | Status |
|---|---|---|
| [1](#1-goals) | Goals | `SETTLED` |
| [2](#2-what-the-research-changed) | What the research changed | — |
| [3](#3-contract-surface) | Contract surface | `SETTLED` |
| [4](#4-threading-split) | Threading split | `SETTLED` |
| [5](#5-what-nifserver-builds) | What NifServer builds | `SETTLED` |
| [6](#6-names) | Names | `SETTLED` |
| [7](#7-animation) | Animation | `SETTLED` |
| [8](#8-materials-and-texture-slots) | Materials and texture slots | `SETTLED` scope / `OPEN` rendering |
| [9](#9-skinning-and-the-actor-path) | Skinning and the actor path | `SETTLED` |
| [10](#10-flatten_static) | `flatten_static` | `SETTLED` |
| [11](#11-lod-is-a-policy-layer-not-nif-content) | LOD is a policy layer, not NIF content | `SETTLED` |
| [12](#12-caching) | Caching | `OPEN` |
| [13](#13-tracker-items-closed-by-research) | Tracker items closed by research | — |
| [14](#14-remaining-open-questions) | Remaining open questions | `OPEN` |
| [15](#15-verification) | Verification | — |

---

## 1. Goals

Unchanged from v1.

| | |
|---|---|
| One entry point | Given a NIF path, return the best Godot tree for that file's actual contents. |
| Honest return | The result reflects the file, not the caller's intent. No per-caller modes. |
| Conformant output | Already Y-up and Godot-forward. No consumer applies an axis correction after the fact. |
| Self-contained | Owns its own queue, budget and stats, like TextureServer. |
| Composed on top | Humanoid stitching, equipment interpretation, rigid-body policy, XEMI tint and `_lod.nif` policy are callers, not modes. |

---

## 2. What the research changed

| v1 position | measured finding | v2 position |
|---|---|---|
| Authored in-NIF LOD drives Godot LOD; native work required to expose `NiLODNode`/`NiRangeLODData`/`NiScreenLODData`/`BSLODTriShape` | **all four have zero occurrences** in 25,760 files | [§11](#11-lod-is-a-policy-layer-not-nif-content) — removed from scope, native work cancelled |
| `flatten_static` is ignored when the file turns out dynamic — "content decides" | — | [§10](#10-flatten_static) — tracker settled the opposite: explicit caller override |
| `await request()` returns an orphan `Node3D` | — | [§3](#3-contract-surface) — owner-aware callback |
| `request_kf()` returns one `Animation` | 4,981 of 5,014 KFs hold one sequence, **33 hold 2–5** | [§7](#7-animation) — returns an `AnimationLibrary` |
| `Animation` is worker-safe because it is not RS-backed | verified on 4.7.1, 8 concurrent workers | [§7](#7-animation) — confirmed, retarget rename is worker-side too |
| FNV has 6 texture slots, 13 is Skyrim-only | **all 56,789 sets declare exactly 6** | [§8](#8-materials-and-texture-slots) — confirmed |
| Slots 3–5 unread is "a real rendering gap" | slot 4 **11.7%**, slot 5 **10.1%**, slot 3 **0.9%** | [§8](#8-materials-and-texture-slots) — read all 6; env-map pair is material, parallax marginal |
| Traversal walks `childRefs`/`effectRefs` | `effectRefs` **empty in all 20,746 NIFs** | [§5](#5-what-nifserver-builds) — `childRefs` only |
| — | 160 of nifly's 320 types occur; nifly instantiates **every block, 0 failures** | [§5](#5-what-nifserver-builds) — no parse-layer stubs needed |
| — | 86% of skinned NIFs carry a flat bone list | [§9](#9-skinning-and-the-actor-path) — never build a `Skeleton3D` from a skin |

---

## 3. Contract surface

`SETTLED`

### 3.1 Public API

| function | params | delivery | thread |
|---|---|---|---|
| `request()` | `nif_path: String`<br>`owner: Node`<br>`on_complete: Callable`<br>`flatten_static := false` | callback with `Node3D` or `null` | callback on main thread |
| `request_kf()` | `kf_path: String` | `AnimationLibrary` | worker-safe |
| `get_stats()` / `reset_stats()` | — | `Dictionary` | main thread |

`_resolve()` (worker) and `_build()` (main) stay internal.

### 3.2 Ownership and lifetime

| | |
|---|---|
| callback target | a method on `owner`, not a closure capturing it; invoked exactly once |
| owner gone | `_build()` is skipped; no orphan is created |
| on success | ownership transfers to the caller, which must parent or free immediately |
| safety net | NifServer verifies the postcondition and frees a still-orphaned live result |
| parenting | NifServer never chooses the parent and never touches a scene tree |
| cancellation | none needed for ordinary teardown — the typed `EsmNode` is the lifetime owner |

### 3.3 Canonical paths

Normalise before cache lookup: `\` → `/`, lowercase, strip a leading `meshes/`. Both
`Weapons\2HandRifle\MicroFusionCell.NIF` and the `meshes/`-prefixed form resolve to one cache
identity. ArchiveServer re-adds `meshes/` exactly once. Empty path is an invalid request.

### 3.4 Failure contract

| input | result |
|---|---|
| missing or malformed | `null` |
| valid but no renderable geometry | a real tree — validity is not conditional on meshes |
| unsupported optional feature | partial representation + diagnostics |

Warnings are emitted once per canonical path; detailed diagnostics are available separately from the
`Node3D`/`null` consumer result.

---

## 4. Threading split

`SETTLED`

| stage | thread | does | never touches |
|---|---|---|---|
| `_resolve()` | worker | `ArchiveServer.read()`, `NifSource.load()`, `TextureServer.warm()` per slot | any cache, any `Node`, any RID-backed resource |
| texture gate | main | wait until every warmed key reports `TextureServer.is_finished()` | — |
| `_build()` | main | `NifTreeBuilder.build()` — nodes, meshes, materials, shapes, animations | — |

### 4.1 Why the split falls here

**Not because of `RID_Owner`.** An earlier version of this section claimed `RID_Owner<T>` locking is
compiled out off the main thread. That is not true of this engine version: `THREAD_SAFE` is a
per-owner template argument, and `mesh_owner`, `texture_owner`, `material_owner`, `shader_owner` and
`skeleton_owner` all request it. The owners that do not are the renderer's own per-instance
bookkeeping, which script never addresses. Nor does Godot forbid building nodes off the main thread —
its own documentation states that creating scene chunks outside the active tree is fine.

Two things actually constrain it:

**The shared caches are main-thread-owned by design.** TextureServer holds `_textures`, `_jobs`,
`_admission` and `_uploads` with no atomics and no mutexes, on the stated basis that only the main
thread mutates them. `_build()` reads that cache for every texture slot. Moving `_build()` to a
worker means making those structures thread-safe for every caller, not just this one. Godot's own
guidance points the same way: one thread loading data is the sanctioned pattern, and the risk it
names for several is precisely shared resources being written by more than one.

**The measurements say the worker half is where the time is.** Over a 60-model burst, with textures
resident:

| stage | time | share |
|---|---:|---:|
| `ArchiveServer.read()` — BSA + inflate | 33.1 ms | 48% |
| `NifSource.load()` — nifly parse | 14.7 ms | 21% |
| `NifTreeBuilder.build()` | 21.4 ms | 31% |

`_resolve()` is already the larger half and is worker-safe by construction — positional `pread` means
concurrent `read_at()` takes no lock, and a parse writes only its own `Document`. `_build()` is
0.36 ms per model, which a frame budget absorbs. Moving it off-main would buy a third of the time in
exchange for making two servers' caches thread-safe.

So the split stands; only its justification changed. Revisit if `_build()` ever dominates.

### 4.2 Budgets

| budget | default | meaning |
|---|---|---|
| `builds_per_frame_budget` | 12 | `_build()` calls drained per frame |
| `num_workers` | -1 | admission cap on concurrent `_resolve()` tasks; `-1` = `max(2, cpus - 1)` |

**Hard rule:** never `add_group_task()` at default `tasks_needed = -1` — it claims every thread in
the pool both servers share, and `_build()` cannot proceed without a real uploaded texture, so
starving TextureServer is a hang, not a stall.

**Ordering is not FIFO.** A plain queue builds the far side of a cell before what is in front of the
player; `world_streamer.gd` already learned this and orders by real circular distance. A NifServer
queue inherits the same requirement.

---

## 5. What NifServer builds

`SETTLED`

### 5.1 Scope of the format

| | |
|---|---:|
| block types occurring in shipped data | **160** of nifly's 320 |
| blocks nifly failed to instantiate | **0** of every block in 25,760 files |
| types needing a parse-layer stub | **none** |

### 5.2 Nodes vs data

Only `NiAVObject`-derived blocks become nodes — 18 types, mapping to 5 Godot classes. Everything
else is reached by link field and becomes data on the node that references it. Full map and
per-type profile: [Research §3](Research/nifserver_design_findings.md).

| Godot class | NIF types | blocks |
|---|---:|---:|
| `Node3D` | 11 | 72,547 |
| `MeshInstance3D` | 3 | 67,974 |
| `GPUParticles3D` | 2 | 1,599 |
| `Camera3D` | 1 | 162 |
| `OmniLight3D` | 1 | 119 |

Traversal follows `childRefs` only — `effectRefs` is empty corpus-wide; lights arrive as ordinary
children. Named nodes are never pruned (only 3.4% are inert, and a pruned node fails silently).

### 5.3 Conversion policy: build it, let the consumer disable it

`SETTLED`

| case | policy | examples |
|---|---|---|
| Godot has a native construct | **build it** | collision, ragdoll, lights, cameras, particles |
| Godot expresses it as state on something else | apply it there | `NiBillboardNode` mode → descendant materials |
| Godot has no construct at all | node metadata | `BSBlastNode` / `BSDamageStage` stages, `BSValueNode` value, `NiBSBoneLODController` |

NifServer does not withhold a construct because no consumer wants it yet. Turning something off is
the consumer's call and is cheap; reconstructing it from a half-conversion is neither.

**Collision and ragdoll are separate by block type, not by heuristic:**

| block | files | becomes |
|---|---:|---|
| `bhkCollisionObject` | 11,134 | ordinary collision body + shapes |
| `bhkSPCollisionObject` | 40 | phantom — triggers, water, traps |
| `bhkBlendCollisionObject` | **60** (56 named `skeleton*.nif`) | `PhysicalBone3D` set under a `PhysicalBoneSimulator3D` |

`PhysicalBoneSimulator3D` is inert until `physical_bones_start_simulation()`, so an actor that does
not want a ragdoll pays nothing behaviourally and calls nothing. `bhkRigidBody` maps to
`PhysicalBone3D` (mass, friction, bounce, damping, gravity scale), its shape to a `CollisionShape3D`
child, and `bhkRagdollConstraint`/`bhkMalleableConstraint`/`bhkLimitedHingeConstraint` to
`joint_type` + `joint_offset`/`joint_rotation`.

> Constraints are **not** a ragdoll signal: 164 files carry one with no `bhkBlendCollisionObject`,
> `bhkLimitedHingeConstraint` alone appearing in 190 files of which 90 are `meshes/armor`.

If the per-actor body count ever measures badly, the consumer frees or disables the simulator
subtree — a decision that needs a profile, not a guess.

---

### 5.3 Stays outside NifServer

Humanoid/creature stitching · equipment and armor-slot interpretation · gender and addon model
selection · rigid-body mass and physics policy · XEMI tint · `_lod.nif` companion policy ·
FaceGen/TRI/EGM · texture decode and cache.

---

## 6. Names

`SETTLED`

Node names are the binding key for animation, attach points and the object palette, so they must
round-trip.

| fact | count |
|---|---:|
| `NiAVObject` names containing a Godot-illegal char (`. : @ / %` `"`) | 44,620 distinct, **41.6% of references** |
| animation target names containing one | 1,317 distinct, 3.4% of references |
| nameless `NiAVObject` blocks | 9,214 — unaddressable, auto-naming is safe |
| files containing a duplicate `NiAVObject` name | **245**, 2,326 surplus names, 105 files with 9+ |

| rule | |
|---|---|
| escape | a reversible mapping applied identically on the NIF and KF sides — **not** a one-way `replace(":", "_")` as `mesh_resolver.gd` does today |
| scope | only named blocks need round-tripping |
| duplicates | Godot auto-renames duplicate siblings, so name lookup is ambiguous in 245 files — resolve against the authored name recorded per node, not `get_node()` |
| resolution order | block's own name → `NiDefaultAVObjectPalette` alias for names no block carries (97 live cases) → ignore null-ref and untargeted aliases |

---

## 7. Animation

`SETTLED`

### 7.1 Return shape

`request_kf()` returns an `AnimationLibrary` keyed by sequence name. 4,981 of 5,014 KFs hold one
sequence, but 33 hold 2–5, so a single-`Animation` return cannot represent the corpus.

Verified on Godot 4.7.1 (`tools/godot_anim_thread_check/`): `Animation`/`AnimationLibrary`
construction, key insertion and `track_set_path()` mutation all run correctly on 8 concurrent
`WorkerThreadPool` threads. `request_kf()` is therefore fully worker-side, retarget renames included.

### 7.2 Addressing

Tracks return with the authored target name as their path. Binding is caller-side, because a KF
addresses a **composed rig** — skeleton plus equipped weapon plus animobjects — not one file.

| addressing form | files | mechanism |
|---|---:|---|
| inline strings | all but 5 | `ControllerLink.nodeName` / `propType` / `ctrlType` / `ctrlID` |
| `NiStringPalette` + byte offsets | **5** (file version 20.0.0.4) | offsets into a palette block |

Both must be supported; the five are player idles (`eatidle`, `pistolvariant01`,
`talk_handsatside_*`) that silently vanish otherwise.

### 7.3 Property and modifier tracks

8,359 links target a property rather than a node, across exactly **11** distinct
`(propType, ctrlType, ctrlID)` triples — a closed, hand-writable mapping table. `(nodeName,
propType)` is unambiguous: no node carries two properties of one type.

Property blocks are shared (34% of `NiMaterialProperty` by 2+ nodes) while shader properties never
are, so a fused Godot material cannot preserve the sharing. **NifServer stamps each node with its
source property block identity**; the caller fans one property track out to every node that shared
that block. Without it, ~16% of property animations drive only one of several meshes.

Particle tracks use the same shape with a modifier name in `ctrlID` — the mechanism should
generalise rather than being material-specific.

### 7.4 Sequences held inside a `.nif`

A `.nif` with its own `NiControllerManager` addresses targets that are nodes in the same file:
doors, lifts, terminals, hatches. Those sequences bind inside `build()` — an `AnimationPlayer` with
one `AnimationLibrary`, tracks pointed at the built nodes (bones as `Skeleton3D:BoneName`). This is
the same self-contained-versus-composed split §9 applies to skinning, and it is what §7.2's
caller-side binding rule leaves room for rather than contradicting: a clip whose targets are all
present needs no caller to resolve them.

A sequence that resolves to nothing is named in `nif_unbound_sequences` metadata. Nothing is
silently dropped, and nothing is guessed at.

Curve extraction covers every interpolator in the corpus that carries data:

| form | files | treatment |
|---|---:|---|
| `NiTransformInterpolator` (+ `BSRotAccumTransfInterpolator`) | 6,850 | keys read verbatim |
| `NiBSplineCompTransformInterpolator` / `NiBSplineTransformInterpolator` | 4,069 | cubic control points, sampled adaptively; flagged `resampled` |
| `NiFloatInterpolator` | 2,852 | keys read verbatim |
| `NiBoolInterpolator` | 1,516 | keys read verbatim, interpolation forced constant |
| `NiPoint3Interpolator` | 835 | keys read verbatim, **no** unit conversion (colours, not positions) |
| `NiBlend*` | 1,169 | reported with no keys — it blends others at runtime and holds none |

`rotationType == XYZ_ROTATION_KEY` stores three per-axis float curves with independent key times;
they are composed into quaternion keys on the union of those times, because a rotation track cannot
carry them separately.

Only `transform` links become tracks today. Property links (§7.3) reach the caller with their keys
but are not bound — the fan-out across shared property blocks is unimplemented.

### 7.5 Key interpolation is a policy, not a mapping

Gamebryo interpolates **per key**; Godot interpolates **per track**. No mapping closes that, so the
track mode is chosen:

| authored `NiKeyType` | Godot track mode | reason |
|---|---|---|
| `QUADRATIC_KEY`, `TBC_KEY` | `CUBIC` | The authored intent is easing. Godot's cubic derives its curve from neighbouring key values rather than the authored tangents — which are not extracted — and that is close enough for "it stops softly". |
| `CONST_KEY` | `LINEAR` | Deliberate. Stepped keys at the engine's ~30 Hz update read as intended on a 360 and as juddering on modern hardware. Smoothing them is an improvement over the original, not a loss of fidelity. |
| `LINEAR_KEY`, `NO_INTERP`, `XYZ_ROTATION_KEY` | `LINEAR` | |

A mixed channel takes `CUBIC` only when eased keys are the majority: cubic through keys authored
linear invents overshoot at direction reversals, so the conservative side is the default.

Resampled (B-spline) channels are always `LINEAR` — the keys are already samples of the curve.

Rejected: baking eased channels to dense linear key runs. It reproduces per-key semantics exactly
and costs a large key count to represent a curve a designer placed as a single easing hint.

### 7.6 `bhkRigidBodyT` carries a transform, both halves of it

`bhkRigidBodyT` means "this body has its own transform"; plain `bhkRigidBody` carries the same
fields inert. Both the translation and the **rotation** apply. Taking only the translation leaves a
rotated collider sitting square to its own mesh — `architecture/strip/NewVegasSign.nif` ships a
quaternion of exactly +90 degrees about X, so its collider's Y and Z extents swap against a 9 m
sign.

The rotation is stored as a `QuaternionXYZW`, unlike the WXYZ `Quaternion` every other block in the
format uses. No component swap is needed here, and applying one silently is the obvious way to get
this wrong twice.

| | count |
|---|---:|
| `bhkRigidBodyT` bodies | 4,612 |
| plain `bhkRigidBody` bodies | 11,963 |
| **`bhkRigidBodyT` with a non-identity rotation** | **751, across 617 files** |

Axis-aligned multiples dominate — 310 at 90 degrees, 211 at 180, 42 at 120 — but 617 files is not a
special case, and the long tail of authored angles (1 to 179 degrees) rules out snapping.

### 7.7 Collision follows its owner

A shape hangs off the node that owns it, one body per distinct owning node, never in bulk at the
root. The owning node's transform is part of the shape's placement, and a node that a sequence
animates carries its collision with it. An animated owner gets an `AnimatableBody3D`; a
`StaticBody3D` that moves collides with nothing it moves into.

---

## 8. Materials and texture slots

Scope `SETTLED` · rendering `OPEN`

All 56,789 `BSShaderTextureSet` blocks declare exactly **6** slots, confirming FNV is 6 and 13 is
Skyrim-only. Measured occupancy:

| slot | convention | occupied | read today |
|---|---|---:|---|
| 0 | diffuse | 99.96% | yes |
| 1 | normal + gloss | 99.61% | yes |
| 2 | glow / emissive | 7.50% | yes |
| 3 | height / parallax | **0.90%** | no |
| 4 | environment map | **11.69%** | no |
| 5 | environment mask | **10.14%** | no |

`_resolve()` reads all 6 unconditionally — an occupied slot is the fact, no shader flag needs to
agree first — and warms every one. Whether `_build()` *renders* slots 3–5 is open: the env-map pair
(4 and 5, ~6,600 and ~5,800 blocks) is a real visual gap worth closing; parallax at 0.9% is
marginal.

---

### 8.1 Texture slots are reported per convention

Slot numbers mean different things depending on which block carries them, so the source reports the
convention rather than merging them. Resolution order matches nifly's own `GetTextureSlot`.

| convention | block | slots | shapes |
|---|---|---|---:|
| `shader_set` | `BSShaderTextureSet` | 0 diffuse · 1 normal · 2 glow · 3 height · 4 env · 5 env mask | 57,942 |
| `texturing_property` | `NiTexturingProperty` → `NiSourceTexture` | 0 base · 1 dark · 2 detail · 3 gloss · 4 glow · 5 bump · 6-9 decal | 4,701 |
| `effect_shader` | `BSEffectShaderProperty` | 0 source · 1 normal · 3 greyscale · 4 env · 5 env mask | 0 |
| *(empty)* | no texture on the shape | | 4,527 |

Slot 2 is glow under the first convention and **detail** under the second. Gating extraction on
`TextureSetRef()` alone leaves every `NiTexturingProperty` shape with no albedo — 1,393 files,
4,679 of those shapes `BSShaderNoLightingProperty`, which is why the symptom is a solid white
unlit panel (terminal screens, effect panels).

Corpus-wide only `base` is occupied on the second convention — 4,701 of 4,701, plus exactly one
`dark`. The remaining slots are mapped for correctness, not because content ships them.

### 8.2 Vertex colour and `NiAlphaProperty`

Vertex colour is load-bearing, not decoration: Bethesda's unlit AO fades and glow overlays carry no
texture at all, so per-vertex colour and its alpha are the only pixels the shape has. A
`StandardMaterial3D` ignores `ARRAY_COLOR` unless `vertex_color_use_as_albedo` is set, so without it
those shapes render as solid opaque white quads.

`NiAlphaProperty.flags` is the niftools bitfield: bit 0 blend enable, bits 1-4 source blend
function, bits 5-8 destination, bit 9 test enable; `threshold` is a 0..255 byte normalized at the
source. The src/dst pair buckets to `mix` / `add` / `multiply` — a census of blend-enabled shapes
across ~2,000 NIFs found exactly those three in use (734/796 mix, 40/796 add for light shafts and
glow, 22/796 multiply for grime decals) and nothing else.

Two engine-level traps, both carried over from the shipping loader:

- **Authored alpha-test threshold 0 is a no-op.** Bethesda keeps pixels where alpha > threshold;
  Godot's scissor discards below it, so 0 keeps everything and tree LOD billboards render as opaque
  squares. Mapped to 0.5, Bethesda's own modal authored value.
- **DXT1 punch-through alpha is lost on GPU upload.** Godot maps `FORMAT_DXT1` to the BC1_**RGB**
  GPU format, opaque by spec, so alpha is discarded by the sampler before any fragment shader runs.
  Not shader-fixable. A blend- or test-enabled shape therefore requests its diffuse through
  TextureServer's `alpha_safe` path, which decompresses to RGBA8 under a `#rgba` cache key.

---

## 9. Skinning and the actor path

`SETTLED`

**NifServer has no humanoid, actor, creature or equipment entry point.** One NIF in, one honest
return out. No single NIF contains an actor; merging is the caller's job.

| fact | |
|---|---:|
| skinned NIFs whose bone list is **flat** — no bone parented to another | **892 of 1,038 (86%)** |
| bone references not parented to another bone | 19,945 of 20,279 (98%) |
| creature skinned NIFs that are flat | 205 of 206 |

A skinned part carries a bone *name list* plus bind transforms, not a skeleton. **NifServer never
resolves a skin into a `Skeleton3D`** — it would be inventing a rig the file does not contain, and a
merge discards it.

| step | who | what |
|---|---|---|
| 1 | NifServer | `MeshInstance3D` + `Skin` built with `add_named_bind(bone_name, bind_pose)`; `skeleton` unset |
| 2 | caller | reparent under its `Skeleton3D`, set `mi.skeleton` |
| 3 | Godot | resolves every named bind against that skeleton's bone names |

Verified on 4.7.1 (`tools/godot_named_bind_check/`): a missing bone raises
`Skin bind #0 contains named bind 'X' but Skeleton3D has no bone by that name.` — loud failure,
unlike the silent `find_bone() == -1` in today's manual path.

**Morph policy:** in-NIF morph geometry (`NiGeomMorpherController` + `NiMorphData`, 55 files) is
NifServer's — it is file content. TRI/EGM FaceGen deformation is external data and stays with the
caller.

---

## 10. `flatten_static`

`SETTLED`, per the tracker.

| | |
|---|---|
| meaning | one wrapper `Node3D` containing one `MeshInstance3D` per mesh; authored hierarchy removed |
| **not** | a mesh merge — each mesh keeps its own surfaces and materials |
| coordinate space | relative to the returned wrapper; no world-space baking |
| collision | each flattened mesh keeps its applicable authored collision |
| dynamic content | flag is an **explicit override** and flattens dynamic NIFs too, discarding their behaviour — it is never silently ignored *(reverses v1)* |
| detection | still used to decide what data to skip decoding, and for diagnostics |
| cache identity | `(canonical_path, flatten_static)` — distinct entries |
| `DirectGeometryBatch` | never used here; remains a separate placement API |

This is a representation flag, not a caller-intent mode: it changes *how much of the file is
expressed*, never *what the file is interpreted as*.

---

## 11. LOD is a policy layer, not NIF content

`SETTLED`

**Canonical source: [`enginedocs/lod.md`](../../enginedocs/lod.md)** and PR #57. That doc establishes
the LOD systems, the VWD gate and the standalone-imposter class; this section records only what
bears on NifServer's contract.

### 11.1 No LOD block type exists in shipped data

| block type | occurrences in 25,760 files |
|---|---:|
| `NiLODNode` · `NiRangeLODData` · `NiScreenLODData` · `BSLODTriShape` · `NiSwitchNode` | **0** |

v1's "Authored LOD drives Godot's LOD" section, its native exposure work, and its two unsettled
sub-questions (`BSLODTriShape` distances, `NiScreenLODData` FOV policy) are **cancelled** — there is
nothing to read. Independently confirmed by PR #57, which checked the Strip-wall/McCarran meshes
directly and found no such blocks.

### 11.2 Three distinct systems, none expressed inside a NIF

| system | assets | gate |
|---|---:|---|
| **Paired object LOD** — `<name>_lod.nif` beside `<name>.nif` | 1,296 companions, one level each (1,283 bare `_lod`, 1 `_lod01`) | VWD flag per `REFR` |
| **Baked terrain tiles** — `<world>.level<N>.x<X>.y<Y>.nif` | 3,567 — level 4 (2,695), 8 (696), 16 (160), 32 (16) | worldspace tile grid + `.dlodsettings` |
| **Baked block stand-ins** — `<world>/blocks/<world>.level4.x<X>.y<Y>.nif` | **561, all level 4** | none authored — needs a near cutoff (PR #57) |
| **Standalone imposter props** — own base record, own mesh | 37 imposter NIFs (21 `_imposter.nif`), mostly `architecture/strip` | `XSRF`/`XSRD` `REFR` subrecords; **not** VWD |

> An earlier draft of this section counted the 561 `blocks/` stand-ins as terrain tiles. They are
> coarse building/skyline geometry sharing a `Buildings.dds` atlas, not terrain — PR #57.

All of them are **plain static NIFs**:

| | root | contents |
|---|---|---|
| object `_lod.nif` | `BSFadeNode` | `NiTriStrips` + `BSShaderPPLightingProperty` + `NiMaterialProperty` |
| terrain tile | `BSMultiBoundNode` | `NiTriShape` / `BSSegmentedTriShape` + `NiAdditionalGeometryData` |

**NifServer returns all of them like any other static NIF.** No special case, no flag, no detection.

> The landscape LOD tree is the *only* place `BSSegmentedTriShape` (849/849 files) and
> `NiAdditionalGeometryData` (3,567/3,567 files, exactly the terrain-tile count) occur. Both types'
> handling is a LOD-path concern, not general geometry.

### 11.3 VWD is a per-`REFR` flag

Bit `0x00008000` in the `REFR` record's own 32-bit header flags. Independently re-confirmed against
`FalloutNV.esm` for this review:

| | |
|---|---:|
| `REFR` records | 307,710 |
| with VWD set | **17,183 (5.6%)** — the most common header-flag bit on `REFR` |
| `McCarranWallLongImposter` (`0x15D24B`) flags | `0x00000400` — **VWD not set** |

Two consequences, both from `enginedocs/lod.md`:

- Having a `_lod.nif` does **not** mean a placement renders at distance. VWD is per-placement, not
  per base record — `NVNellisQuonsetHut01/02` (4 placements) and `CraneStatic01` (2) all ship LOD
  companions with VWD unset.
- The standalone imposter class is gated by `XSRF`/`XSRD` instead, and has no authored fade at all,
  which is the bug PR #57 fixed with a near cutoff.

### 11.4 Where the policy lives

| input | source |
|---|---|
| whether a placement renders at distance | VWD bit on the `REFR`, or `XSRF`/`XSRD` for imposters |
| which file to load | naming convention, or the tile grid |
| terrain extent and level range | `.dlodsettings` per worldspace |
| crossover and fade distances | INI per quality preset — `fBlockLoadDistance` 125000, `fBlockLoadDistanceLow` 25000→50000, `fLODFadeOutMultObjects` 2.5→15.0 |
| project-side tunables | `GodotBryoSettings` (PR #57) — LOD0 crossover, margin, LOD1 max range, distant near cutoff |

The consumer resolves which path to request, then sets `visibility_range_begin`/`end` and a fade
mode on the result. `_apply_lod_visibility_range()` and `DirectGeometryBatch` already implement that
shape.

---

## 12. Caching

`OPEN`

Settled: one resolve cache keyed `(canonical_path, flatten_static)`, holding only Resources and
plain data; a fresh node tree is constructed per delivered instance; cache hits still consume the
build budget. Prototype-tree caching with `Node.duplicate()` is a measured v2 investigation, not a
v1 assumption.

Open: cache layering, null/failure caching and invalidation, eviction policy, disk-cache scope.
Material cache identity should account for [§7.3](#73-property-and-modifier-tracks) sharing —
identity must include the source property block, not just the resolved parameters.

---

## 13. Tracker items closed by research

| tracker item | resolution |
|---|---|
| Dynamic tree fidelity — duplicate/empty names, node paths | §6 — measured: 9,214 nameless, 245 files with duplicates, 41.6% illegal chars |
| Skinned construction — how `Skin` is created, external skeletons | §9 — named binds, caller supplies the skeleton |
| Morph policy | §9 — in-NIF morph is NifServer's, TRI/EGM is the caller's |
| KF contract — worker safety, one clip or a set | §7 — verified worker-safe; `AnimationLibrary` |
| Track binding convention | §7.2 — five-string addressing, both forms |
| Retargeting | §7.1 — a worker-side rename; real retarget needs the composed rig, so caller-side |
| Slots 3–5 scope | §8 — occupancy measured |
| Native slot exposure / real FNV slot count | §8 — 6 slots confirmed in data |
| Authored in-NIF LOD census | §11 — absent |
| `BSLODTriShape` distances | §11 — absent |
| `NiScreenLODData` policy | §11 — absent |
| Public API completeness / failure contract / delivery / ownership / canonical paths | §3 |

---

## 14. Remaining open questions

| # | Question | Blocks |
|---|---|---|
| 1 | `NifResolveResult` concrete schema, including `is_flattened` and per-node source-property identity | implementation |
| 2 | Do `_build()` renderers cover texture slots 4/5 (env map), or only preserve them? | §8 |
| 3 | Collision layout — one body per `bhkCollisionObject` with shapes flattened, or shapes as siblings | §5 |
| ~~4~~ | **Closed** — yes, `PhysicalBone3D` under an inert `PhysicalBoneSimulator3D` ([§5.3](#53-conversion-policy-build-it-let-the-consumer-disable-it)) | — |
| ~~5~~ | **Closed** — pushed onto descendant materials per [§5.3](#53-conversion-policy-build-it-let-the-consumer-disable-it); the mechanism is settled, the mode mapping is implementation | — |
| 6 | Cache layering, null caching, eviction, disk-cache scope | §12 |
| 7 | Root `-90° X` conversion — numeric tests, and which callers drop their own conversion when | migration |
| 8 | Migration boundary — per-caller adapter list for every `GamebryoMeshResolver` caller | migration |
| 9 | Texture request descriptor shape; alpha-safe and normal-map green-channel conventions | §8 |
| 10 | Nameless `BSMultiBoundNode` collapse (~4,100 nodes) — blocked on wrapper-transform check | §5 |

---

## 15. Verification

| gate | status |
|---|---|
| corpus parse | **done** — nifly loads 25,760/25,760, 0 failures, 0 uninstantiable blocks |
| block-type census parity | **done** — independent Python and nifly scans agree on all 160 types |
| engine behaviour: named skin binds | **done** — `tools/godot_named_bind_check/` |
| engine behaviour: worker-thread `Animation` | **done** — `tools/godot_anim_thread_check/` |
| parity against `mesh_resolver` — transforms, vertex counts, materials, binds | outstanding |
| thread tests — concurrent real-data resolve/decode, no shared cursor or cross-thread RID | outstanding |
| frame-budget tests — builds and uploads within budget under backlog | outstanding |
| visual tests — axis conversion, alpha, normal maps, collision, repeated instances | outstanding |

Corpus scanners and engine checks live in `tools/`; see
[Research §12](Research/nifserver_design_findings.md).
