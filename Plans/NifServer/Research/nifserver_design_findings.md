# NifServer: Structural Findings and Design Decisions

Measured facts about the Fallout: New Vegas NIF/KF corpus, and the NifServer design decisions
that follow from them. Every figure is from a full scan of the shipped data, not a sample.

**Status legend:** `SETTLED` = decided · `RECOMMENDED` = proposed, not yet accepted · `OPEN` = undecided

---

## Index

| # | Area | Status |
|---|---|---|
| [0](#0-corpus-and-method) | Corpus and method | — |
| [1](#1-block-type-census) | Block type census | `SETTLED` |
| [2](#2-node-vs-data-split) | Node vs data split | `SETTLED` |
| [3](#3-niavobject---godot-node-map) | `NiAVObject` -> Godot node map | `RECOMMENDED` |
| [4](#4-vertex-colours) | Vertex colours | `SETTLED` |
| [5](#5-nameless-niavobjects) | Nameless `NiAVObject`s | `SETTLED` / collapse `OPEN` |
| [6](#6-node-names-and-godot-mapping) | Node names and Godot mapping | `SETTLED` |
| [7](#7-animation-targeting) | Animation targeting | `SETTLED` |
| [8](#8-nidefaultavobjectpalette-aliasing) | `NiDefaultAVObjectPalette` aliasing | `RECOMMENDED` |
| [9](#9-property-addressing) | Property addressing | `RECOMMENDED` |
| [10](#10-particle-modifier-addressing) | Particle modifier addressing | `OPEN` |
| [11](#11-multi-file-assembly-the-actor-path) | Multi-file assembly (the actor path) | `SETTLED` / ragdoll `OPEN` |
| [12](#12-open-questions) | Open questions | `OPEN` |
| [13](#13-tooling) | Tooling | — |
| [14](#14-verification-against-nifly) | Verification against nifly | `SETTLED` |

---

## 0. Corpus and method

All `.nif` and `.kf` files in `fresh_nv_copy/Data/*.bsa` — base game, all DLC, all pre-order packs,
`Update.bsa`. No loose `.nif`/`.kf` files exist outside the archives.

| | count |
|---|---:|
| `.nif` files | 20,746 |
| `.kf` files | 5,014 |
| total parsed | 25,760 |
| parse failures | 0 |

NIF versions: 20.2.0.7 user 11 (25,754 files, BS stream 14–34), 20.0.0.4 user 10/11 (6 files).

Scans parse block headers directly and use the header's `blockSizes` table to seek to individual
blocks. Block-offset arithmetic is validated two ways: geometry block totals match the census
exactly (67,972), and all 1,164 object-palette blocks terminate precisely on their block boundary.

---

## 1. Block type census

`SETTLED`

| | count |
|---|---:|
| distinct block types present in the data | **160** |
| nifly-registered types with zero occurrences | **160** |
| types present but not registered by nifly | **0** |

nifly registers 320 types. Exactly half never appear in any shipped asset.

**Decision:** `Plans/nifly_registered_nif_types.md` is culled to the 160 present types. Full
per-type file/block counts are in `Plans/nif_type_census.md` and `Plans/nif_type_census.json`.

**Notable absences** (present in community mods, absent from shipped data): `NiVertexColorProperty`,
`NiZBufferProperty`, `RootCollisionNode`, `NiKeyframeController`/`NiKeyframeData`, the pre-`NiPSys`
particle stack, all `bhkCompressedMeshShape` and `BSTriShape`-family geometry.

**56 types appear in fewer than 25 files each**, down to single occurrences (`bhkNiTriStripsShape`,
`bhkBreakableConstraint`, `BSWArray`, `NiPSysResetOnLoopCtlr`, `BSMultiBoundSphere`). Each is listed
with an example asset path in the census doc.

Rarity does not imply optional: `NiStringPalette` occurs in 5 files and all 5 are unreadable without
it ([§7.4](#74-second-addressing-mechanism-nistringpalette)). Judge each rare type by what breaks
without it, not by its count.

nifly instantiated **every block in every file** — 0 blocks returned null from `GetBlock<NiObject>`
([§14](#14-verification-against-nifly)) — so no type in this list needs a parse-layer stub.

---

## 2. Node vs data split

`SETTLED`

### 2.1 Data blocks are never children

`NiNode::childRefs` is typed `NiBlockRefArray<NiAVObject>` (`native/nifly/include/Nodes.hpp:15`).
Only `NiAVObject`-derived blocks can appear in it. Data is reached by named link fields:

| channel | declared on | reaches |
|---|---|---|
| `childRefs` | `NiNode` | scene-graph children (`NiAVObject` only) |
| `effectRefs` | `NiNode` | lights — **never populated in shipped data**, see [§2.4](#34-effectrefs-is-never-used) |
| `propertyRefs` | `NiAVObject` | `NiProperty` list |
| `collisionRef` | `NiAVObject` | `NiCollisionObject` → body → shape tree |
| `controllerRef`, `extraDataRefs` | `NiObjectNET` | controller chain, extra data |
| type-specific refs | `NiGeometry::dataRef`, `BSMultiBoundNode`, particle modifier lists | remainder |

Traversal is: walk `childRefs`/`effectRefs` to build the node tree; at each node follow the other
channels to gather what decorates it. The child array *is* the node set.

### 2.2 Classification by base class

18 of 160 types are `NiAVObject`-derived. These and only these become Godot nodes.

| base class | types | Godot target |
|---|---:|---|
| **`NiAVObject`** | **18** | **Node3D / MeshInstance3D / Camera3D / Light3D / GPUParticles3D** |
| `NiProperty` | 10 | material on the mesh |
| `NiGeometryData` | 4 | `ArrayMesh` surface |
| `NiExtraData` | 10 | node metadata |
| `NiTimeController` | 33 | `AnimationPlayer` tracks |
| `NiInterpolator` | 17 | track keys |
| `bhkSerializable` | 23 | `CollisionShape3D`, joints |
| `NiCollisionObject` | 3 | the physics body |
| `NiSkin*` | 4 | `Skeleton3D` + `Skin` |
| `NiPSysModifier` | 19 | particle process material |
| plain `NiObject` | 19 | data on the referencing block |

**The 18 node types:** `NiTriStrips`, `BSFadeNode`, `NiNode`, `NiTriShape`, `BSMultiBoundNode`,
`BSSegmentedTriShape`, `NiParticleSystem`, `NiBillboardNode`, `NiCamera`, `BSValueNode`,
`BSOrderedNode`, `BSBlastNode`, `NiPointLight`, `BSDamageStage`, `BSMasterParticleSystem`,
`NiAmbientLight`, `BSStripParticleSystem`, `BSDebrisNode`.

### 2.3 Exception: transform-bearing non-nodes

"Carries a transform" does not select `NiAVObject` exactly. Collision is a parallel transform
hierarchy hanging off `collisionRef`:

| type | files |
|---|---:|
| `bhkRigidBodyT` | 3,531 |
| `bhkTransformShape` | 47 |
| `bhkConvexTransformShape` | 34 |
| `bhkListShape` (nests shapes) | 141 |

**Recommendation:** flatten into each `CollisionShape3D`'s local transform. Godot has no
"shape that transforms another shape" concept and the nesting is shallow.

### 2.4 Pruning

`SETTLED` — **named `NiAVObject` nodes are never pruned.** Every one is emitted as a node with its
name preserved verbatim.

Measured reward (`tools/nif_xcheck/prune_candidates.cpp`):

| named `NiNode`-derived blocks | 68,189 |
|---|---:|
| never an animation target anywhere in the corpus | 32,598 |
| exactly one child | 23,023 |
| **inert pass-through** (untargeted + one child + no collision, controller, properties or extra data) | **2,316 (3.4%)** |
| of those, identity transform (prunable with no transform folding) | **1,600 (2.3%)** |

Risk against that 3.4%:

| | |
|---|---|
| name-based binding is the addressing mechanism | animation targets, attach points and the object palette all resolve by name |
| safety is only assessable corpus-wide | a KF targets NIFs it is not packaged with ([§7](#7-animation-targeting)), so no per-file decision is sound |
| the corpus is not the whole risk surface | third-party meshes and ESM/script name lookups are outside anything measurable here |
| failure mode is silent | a pruned node does not error; the track binds to nothing and the animation is quietly wrong |

The nameless collapse in [§5](#5-nameless-niavobjects) is a separate and larger win — ~4,100 nodes,
unaddressable by construction, so none of the above applies to it.

---

## 3. `NiAVObject` -> Godot node map

`RECOMMENDED`

Profiled through nifly with `tools/nif_xcheck/avobject_shape.cpp`, over all 20,746 NIFs.

### 3.1 The map

`children` columns are meaningful only for `NiNode`-derived types; `skinned` means the geometry
carries a skin instance; `anim-targeted` counts blocks whose name appears in some sequence.

| NIF type | blocks | nameless | children (avg / max) | collision | skinned | anim-targeted | Godot node |
|---|---:|---:|---:|---:|---:|---:|---|
| `NiNode` | 51,831 | 5 | 1.38 / 229 | 6,885 | — | 34,933 | `Node3D` |
| `NiTriStrips` | 57,796 | 0 | leaf | — | 84 | 3,178 | `MeshInstance3D` |
| `BSFadeNode` | 15,121 | 167 | 2.99 / 709 | 9,965 | — | 318 | `Node3D` (file root) |
| `NiTriShape` | 9,189 | 3,703 | leaf | — | **5,312** | 242 | `MeshInstance3D` |
| `BSMultiBoundNode` | 4,137 | 4,136 | 1.14 / 3 | — | — | 0 | `Node3D`, or collapse (§5) |
| `NiParticleSystem` | 1,587 | 0 | leaf | — | — | 1,331 | `GPUParticles3D` |
| `BSSegmentedTriShape` | 989 | 989 | leaf | — | 0 | 0 | `MeshInstance3D` + segment metadata |
| `NiBillboardNode` | 689 | 0 | 1.19 / 6 | — | — | 310 | `Node3D` + billboard mode on child materials |
| `BSValueNode` | 482 | 0 | 0.04 / 1 | — | — | 30 | `Node3D` + value metadata |
| `NiCamera` | 162 | 144 | leaf | — | — | 8 | `Camera3D` |
| `NiPointLight` | 119 | 28 | leaf | — | — | 53 | `OmniLight3D` |
| `BSOrderedNode` | 81 | 0 | 5.05 / 15 | — | — | 0 | `Node3D` + alpha-sort metadata |
| `BSBlastNode` | 81 | 0 | leaf | — | — | 0 | `Node3D` + destruction metadata |
| `BSDamageStage` | 69 | 0 | 2.99 / 29 | — | — | 0 | `Node3D` + destruction metadata |
| `BSMasterParticleSystem` | 38 | 38 | 1.00 / 1 | — | — | 0 | `Node3D` (particle container) |
| `BSStripParticleSystem` | 12 | 0 | leaf | — | — | 4 | `GPUParticles3D` (ribbon) |
| `NiAmbientLight` | 12 | 3 | leaf | — | — | 8 | no direct equivalent — `Node3D` + metadata |
| `BSDebrisNode` | 6 | 0 | leaf | — | — | 0 | `Node3D` + destruction metadata |

### 3.2 Godot classes required

| Godot class | NIF types mapped | blocks |
|---|---:|---:|
| `Node3D` | 11 | 72,547 |
| `MeshInstance3D` | 3 | 67,974 |
| `GPUParticles3D` | 2 | 1,599 |
| `Camera3D` | 1 | 162 |
| `OmniLight3D` | 1 | 119 |
| **total** | **18** | **142,401** |

Four Godot classes carry behaviour. The other 11 NIF types are `Node3D` plus metadata, so the
construction surface is far smaller than 18 types suggests.

### 3.3 What the profile establishes

- **Skinning is a `NiTriShape` concern.** 5,312 of 9,189 `NiTriShape` (58%) are skinned, against 84
  of 57,796 `NiTriStrips` (0.1%). Character and armour geometry is `NiTriShape`; static world
  geometry is `NiTriStrips`. `BSSegmentedTriShape` is never skinned despite the dismemberment
  association.
- **Vertex colours split the same way:** 46,195 of 57,796 `NiTriStrips` carry them versus 763 of
  9,189 `NiTriShape`.
- **`BSFadeNode` is the collision carrier.** 9,965 of 15,121 hold a `collisionRef`, plus 6,885
  `NiNode`. Collision attaches near the root, not at the leaves.
- **`NiNode` is what animation drives:** 34,933 of 51,831 are named in some sequence, versus 3,178
  `NiTriStrips` and 242 `NiTriShape`.
- **Three `Bethesda` node types are pure leaf markers** — `BSBlastNode`, `BSDebrisNode` and 461 of
  482 `BSValueNode` have no children at all. `BSOrderedNode` and `BSDamageStage` are real containers.
- **`NiBillboardNode` has no Godot counterpart.** Godot expresses billboarding as a material flag,
  so the node's mode enum must be pushed down onto descendant materials.


### 3.4 `effectRefs` is never used

`NiNode::effectRefs` is empty in **all 20,746 NIFs** — zero populated arrays corpus-wide. Lights are
reached as ordinary `childRefs` entries, since `NiDynamicEffect` derives from `NiAVObject`.
Traversal only needs `childRefs`.

### 3.5 Open items

| # | Question | Blocks |
|---|---|---|
| 1 | `NiBillboardNode` has no Godot counterpart — Godot expresses billboarding as a material flag. The node's mode enum must be pushed down onto descendant materials, coupling node behaviour to material construction. | shares a decision with §9 |
| 2 | `NiAmbientLight` has no per-object equivalent in Godot. At 12 blocks, carrying it as metadata and ignoring it is likely correct. | — |
| 3 | ~~`BSSegmentedTriShape` segments — purpose unestablished~~ **Closed:** all 849 files sit in the landscape LOD tree (`meshes/landscape/lod`), as do all 3,567 `NiAdditionalGeometryData` files. Not dismemberment. | — |

---

## 4. Vertex colours

`SETTLED`

`NiVertexColorProperty` has zero occurrences, but vertex colours are pervasive. In FO3/NV the
colour *data* lives in `NiGeometryData`; whether it is applied is a shader flag on
`BSShaderPPLightingProperty`. `NiVertexColorProperty` is the Oblivion-era fixed-function control
block and is dead.

| | count |
|---|---:|
| NIFs containing geometry data | 20,444 |
| **NIFs with per-vertex colours** | **12,408 (61%)** |
| geometry blocks with vertex colours | 46,958 / 67,972 |
| coloured vertices | 23,754,470 |

Heaviest directories: `meshes/dungeons` 2,666 / 2,821 files · `meshes/architecture` 2,168 / 2,594 ·
`meshes/nvdlc03` 891 / 1,170.

Terrain colour is unrelated to NIF: it is the LAND record's `VCLR` subrecord, already handled at
`native/src/esm/esm_file.cpp:1410` and `project/gamebryo/terrain3d_bridge.gd:284`.

**Decision:** drop `NiVertexColorProperty`; vertex-colour handling is mandatory via
`NiGeometryData.hasVertexColors` + shader flag.

---

## 5. Nameless `NiAVObject`s

`SETTLED` (unaddressable) · collapse `OPEN`

Nameless `NiAVObject` blocks are unreachable by any string-keyed mechanism in the native engine.
Two independent proofs:

| evidence | result |
|---|---|
| blank `nodeName` across the 291,472 links that use inline string addressing | **0** |
| empty names across all 26,022 `NiDefaultAVObjectPalette` entries | **0** |

365 further links in 5 files carry a blank `nodeName` because they use the older string-palette
addressing described in [§7.4](#74-second-addressing-mechanism-nistringpalette), not because they
target a nameless node.

The palette is Gamebryo's own `name → NiAVObject` lookup table (`AVObject`, `Objects.hpp:64`).
Nameless objects are not in it.

**9,214 nameless blocks across 4,497 files:**

| type | count | role |
|---|---:|---|
| `BSMultiBoundNode` | 4,136 | culling wrapper |
| `NiTriShape` | 3,703 | leaf geometry |
| `BSSegmentedTriShape` | 989 | leaf geometry |
| `BSFadeNode` | 167 | file root |
| `NiCamera` | 144 | — |
| `BSMasterParticleSystem` | 38 | — |
| `NiPointLight` / `NiAmbientLight` | 31 | — |
| `NiNode` | 6 | — |

Child counts of the 4,346 nameless `NiNode`-derived blocks:

| children | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8+ |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| blocks | 3,865 | 136 | 223 | 4 | 13 | 15 | 9 | 81 |

None have zero children.

**Decisions:**
- Nameless nodes need no name mapping. Godot auto-naming is safe.
- **Collapse opportunity (`OPEN`, deferred):** a nameless single-child `BSMultiBoundNode` is
  unaddressable, carries no geometry, and exists only to hang a `BSMultiBound` off a subtree.
  Folding the bound onto the child as metadata removes ~4,100 nodes across 4,497 files with zero
  addressability risk. Blocker to verify first: whether the wrapper transform is identity.

---

## 6. Node names and Godot mapping

`SETTLED`

Godot 4 forbids `. : @ / %` and `"` in node names; `:` is also the `NodePath` property separator.

| name set | distinct | with illegal chars | share of references |
|---|---:|---:|---:|
| `NiAVObject` names in NIFs | 73,278 | 44,620 | **41.6%** |
| animation target names | 8,096 | 1,317 | **3.4%** (9,952 refs) |

The dominant illegal character is `:`, from the exporter's `:0`/`:1` multi-material split suffix
(`HeadAnims:0`, `##Screen:0`, `Object01:2`). Additionally **9,214 `NiAVObject` blocks have an empty
name** and will be auto-named.

**Decision:** a simple reversible escape mapping, applied identically on the NIF and KF sides.
Correctness surface is only the **1,317** illegal-char names that animations actually target —
not all 44,620 — because unaddressable nodes ([§5](#5-nameless-niavobjects)) need no round-trip.

Godot's default sanitisation must not be relied on: it would turn `HeadAnims:0` into `HeadAnims0`
and silently break the KF binding.

---

## 7. Animation targeting

`SETTLED`

Targeting is by string, via `ControllerLink` (`native/nifly/include/Animation.hpp:1150`), keyed on
five strings: `nodeName`, `propType`, `ctrlType`, `ctrlID`, `interpID`.

| | links | sequences |
|---|---:|---:|
| inline string addressing | 291,472 (260,317 in `.kf`) | 7,478 |
| string-palette addressing ([§7.4](#74-second-addressing-mechanism-nistringpalette)) | 365 | 5 |
| **total** | **291,837** | **7,483** |

The classification in §7.1 covers the 260,317 inline-addressed `.kf` links.

### 7.1 What KF links target

| target resolves to | links | share |
|---|---:|---:|
| a name that is skin-weighted somewhere (a true bone) | 233,295 | 89.6% |
| `NiNode`, not skin-weighted | 22,064 | 8.5% |
| `NiTriStrips` | 2,871 | 1.1% |
| `NiTriShape` | 1,115 | 0.4% |
| `NiParticleSystem` | 218 | — |
| `NiBillboardNode` / `BSFadeNode` / `NiPointLight` | 82 | — |
| no block of that name exists in any shipped NIF | 672 | 0.3% |

~10% of animation channels drive things that are not bones, including geometry and particle systems.

### 7.2 `_male` KFs vs `skeleton.nif`

| | count |
|---|---:|
| `NiAVObject` nodes in `meshes/characters/_male/skeleton.nif` | 67 |
| `.kf` files under `meshes/characters/_male/` | 2,251 |
| distinct target names across those KFs | 658 |
| targets present in `skeleton.nif` | **65** |
| targets absent from `skeleton.nif` | **593** |
| skeleton nodes never targeted | **2** (`Camera3rd`, `Scene Root`) |

The 593 absent names live in other files, confirmed by lookup:

| target | owner |
|---|---|
| `##Clip`, `##Trigger`, `##SpeedLoader`, `##Cover`, `##Stock` | weapon NIFs (`meshes/weapons/2handautomatic/servicerifle.nif`, …) |
| `##Screen:0` | `meshes/animobjects/nvpropreflectron.nif` |
| `HeadAnims:0` | a `NiTriShape` **inside** `skeleton.nif` |

A KF is authored against a **composed runtime rig** — skeleton + equipped weapon + attached
animobjects — not against any single NIF.

### 7.3 Skeleton nodes that are not skin-weighted

Animated every frame, but weighted by no skin:

`Bip01 NonAccum` (4,959 KFs) · `Weapon` (1,895) · `Camera1st` (428) · `Bip01 R Hand01`–`04`
(350 each) · `Bip01 L Hand01`–`04` (~309 each) · `Bip01 Translate` · `Bip01 Rotate` · `Bip01 TailNub`

**Decisions:**
- KFs load independently into plain Godot `Animation` resources, retargeted at construction or
  later. This is the only approach that works — the nodes half the tracks address belong to a file
  that is not loaded yet and varies per equipped item.
- **Every node in `skeleton.nif` becomes a `Skeleton3D` bone, weighted or not.** Building bones
  from skin-weighted nodes only loses root motion (`Bip01 NonAccum`) and all attach points.
- Track paths stay keyed on the raw NIF name; resolution happens at bind time against
  skeleton ∪ attached-weapon ∪ attached-animobject.

### 7.4 Second addressing mechanism: `NiStringPalette`

`ControllerLink`'s inline `nodeName`/`propType`/`ctrlType`/`ctrlID`/`interpID` strings are present
only when file version >= 20.1.0.1. Below that the link instead carries a `NiStringPalette`
reference plus byte offsets into it (`nodeNameOffset`, `propertyTypeOffset`, `controllerTypeOffset`,
`controllerIDOffset`, `interpIDOffset`).

Five shipped files use it, all at file version 20.0.0.4, all player idle animations:

| file | version | links | `NiStringPalette` |
|---|---|---:|---|
| `meshes/characters/_male/idleanims/talk_handsatside_moving.kf` | 20.0.0.4 user 10 | 73 | block 2 |
| `meshes/characters/_male/idleanims/talk_handsatside_moving2.kf` | 20.0.0.4 user 10 | 73 | block 2 |
| `meshes/characters/_male/idleanims/talk_handsatside_still2.kf` | 20.0.0.4 user 10 | 73 | block 2 |
| `meshes/characters/_male/idleanims/pistolvariant01.kf` | 20.0.0.4 user 11 | 73 | block 2 |
| `meshes/characters/_male/idleanims/eatidle.kf` | 20.0.0.4 user 11 | 73 | block 2 |

Every link in all five is offset-addressed; none carries an inline name.

**Requirement:** the KF loader must support both addressing forms, resolving offsets against the
referenced `NiStringPalette`. Handling only the inline form silently drops these five idles.

---

## 8. `NiDefaultAVObjectPalette` aliasing

`RECOMMENDED`

The palette is a load-bearing alias table, not redundant metadata.

| | count |
|---|---:|
| palette blocks | 1,164 |
| entries | 26,022 |
| entry name matches referenced block's own name | 25,410 |
| **entry name mismatches** | **280** |
| entries with a null `objectRef` | 332 |
| entries with an empty name | 0 |

**All 280 mismatched palette names match no block in their file.** Shape: 216 are
`blockname + ":N"`, 10 other prefix relationships, 54 unrelated. Distribution is **DLC-only** —
nvdlc03 (141), nvdlc04 (71), nvdlc01 (50), nvdlc02 (18), **zero in the base game**. A specific
exporter version, not a format property.

**97 of the 280 are targeted by a sequence in the same file.** For those the palette is the only
resolution path.

### Worked case: `meshes/nvdlc04/dungeons/utemple/nvdlc04uskydome.nif`

```
block [0]  BSFadeNode   'NVDLC04USkyDome'
block [20] NiTriStrips  'NVDLC04USkyDome NonAccum'

palette: 'NVDLC04USkyDome:2'        -> block 20  (own name 'NVDLC04USkyDome NonAccum')
         'NVDLC04USkyDome NonAccum' -> null

sequence 'Idle':
  node='NVDLC04USkyDome:2' prop='NiTexturingProperty' ctrl='NiTextureTransformController' ctrlID='0-0-TT_TRANSLATE_V'
  node='NVDLC04USkyDome:2' prop='NiTexturingProperty' ctrl='NiTextureTransformController' ctrlID='0-0-TT_TRANSLATE_U'
  node='NVDLC04USkyDome:2' prop='NiMaterialProperty'  ctrl='NiMaterialColorController'    ctrlID='SELF_ILLUM'
```

The mesh was authored as `NVDLC04USkyDome:2`, the animation bound to that name, then the exporter
renamed the block to `... NonAccum` and did not propagate it. The palette retains the old name
pointing at the real block and the new name pointing at nothing. Without palette lookup all three
tracks fail to bind and the sky dome stops scrolling.

**Recommended resolution precedence:**
1. block's own `name` (covers 25,410 / 26,022)
2. palette alias, for any name no block carries (the 97 live cases)
3. ignore null-`objectRef` entries and untargeted aliases (183 + 332, all inert)

Cost is negligible: 1,164 palettes corpus-wide.

**Caveat:** engine palette consultation is inferred from the data being the only resolution path
for 97 live tracks. Not verified against engine behaviour.

---

## 9. Property addressing

`RECOMMENDED`

### 9.1 The vocabulary is closed

All **8,359** property-targeting links in the game resolve to **11** distinct
`(propType, ctrlType, ctrlID)` triples:

| propType | ctrlType | ctrlID | links |
|---|---|---|---:|
| `NiMaterialProperty` | `NiMaterialColorController` | `SELF_ILLUM` | 2,206 |
| `NiMaterialProperty` | `NiAlphaController` | — | 1,334 |
| `NiMaterialProperty` | `BSMaterialEmittanceMultController` | — | 1,182 |
| `NiTexturingProperty` | `NiTextureTransformController` | `0-0-TT_TRANSLATE_V` | 964 |
| `NiTexturingProperty` | `NiTextureTransformController` | `0-0-TT_TRANSLATE_U` | 934 |
| `NiTexturingProperty` | `NiTextureTransformController` | `0-0-TT_SCALE_U` | 404 |
| `NiTexturingProperty` | `NiTextureTransformController` | `0-0-TT_SCALE_V` | 383 |
| `BSShaderPPLightingProperty` | `BSRefractionStrengthController` | — | 326 |
| `BSShaderPPLightingProperty` | `BSRefractionFirePeriodController` | — | 271 |
| `NiTexturingProperty` | `NiTextureTransformController` | `0-0-TT_ROTATE` | 233 |
| `NiMaterialProperty` | `NiMaterialColorController` | `SPEC` | 122 |

Consequences:
- The `0-0` prefix is `shaderMap=0, textureSlot=BASE_MAP`. **Only the base map is ever UV-animated**
  — no slot dispatch needed.
- `NiAlphaController` targets `NiMaterialProperty`, driving the material's alpha *value*.
  **`NiAlphaProperty` owns zero controllers corpus-wide** — blend state is never animated. Same for
  `NiStencilProperty`.
- Only 2 of the 4 `TargetColor` enum values are ever used (`TC_SELF_ILLUM`, `TC_SPECULAR`; never `TC_AMBIENT` or `TC_DIFFUSE`). All 5 `TexTransformType` values are used.

### 9.2 `(nodeName, propType)` is unambiguous

No node anywhere carries two properties of the same type. Every property type shows a flat
multiplicity of exactly 1 (`NiMaterialProperty` 64,854 nodes, `NiAlphaProperty` 29,984,
`BSShaderPPLightingProperty` 58,706, …). `ctrlID` distinguishes *channel within one property*,
never *which property*.

### 9.3 Properties are shared; shader properties are not

Reference counts per property block within a file:

| property type | 1 node | 2 | 3 | 4 | 5 | 6+ |
|---|---:|---:|---:|---:|---:|---:|
| `NiMaterialProperty` | 19,915 | 4,867 | 1,994 | 1,331 | 691 | 1,615 |
| `NiAlphaProperty` | 10,474 | 2,478 | 984 | 577 | 190 | 550 |
| `NiTexturingProperty` | 2,355 | 314 | 100 | 76 | 47 | 126 |
| `NiStencilProperty` | 481 | 186 | 61 | 36 | 22 | 53 |
| **`BSShaderPPLightingProperty`** | **58,706** | 0 | 0 | 0 | 0 | 0 |
| **`BSShaderNoLightingProperty`** | **9,582** | 0 | 0 | 0 | 0 | 0 |

~34% of material properties are shared by 2+ nodes. Shader properties are strictly one per shape.

A Godot `Material` fuses blocks with **different sharing granularity**. One `NiMaterialProperty`
shared across 6 shapes, each with its own `BSShaderPPLightingProperty`, produces 6 distinct Godot
materials — destroying sharing that is semantically load-bearing, since natively a controller bound
through one node mutates the shared block and all 6 shapes change.

Impact, measured on the 5,001 fully-resolvable embedded-sequence property links:

| target property is | links |
|---|---:|
| unshared | 4,183 |
| shared by 2 nodes | 442 |
| shared by 3+ nodes | 376 |

**~16% of property animations would silently drive only one of several meshes** under naive
fuse-and-duplicate.

### 9.4 Recommendation: fan out at retarget time

Sharing cannot be preserved inside a Godot material, and does not need to be — the sharing set is
known at NIF-load time. One NIF property track expands into N Godot tracks, one per node that
shared the source block. Semantics then match exactly.

**API requirement:** NifServer must stamp each node with its source property block identity per
type (e.g. `nif_prop/NiMaterialProperty = <block id>`) so the retargeter can answer "which other
nodes shared this block".

Track paths become `<node>:material_override:<mapped_property>`, with §9.1 supplying the mapping:
`SELF_ILLUM` → emission · `BSMaterialEmittanceMultController` → emission energy · `NiAlphaController`
→ albedo alpha · the five `TT_*` → base-map UV transform · refraction pair → shader uniforms.

### 9.5 Properties own controllers directly

| property type | blocks with non-null `controllerRef` | total |
|---|---:|---:|
| `NiMaterialProperty` | 1,772 | 30,413 |
| `NiTexturingProperty` | 1,093 | 3,018 |
| `BSShaderPPLightingProperty` | 87 | 58,706 |
| `NiAlphaProperty`, `NiStencilProperty`, others | 0 | — |

A NIF can carry a *running* property animation with no sequence addressing it — the ambient
scrolling/pulsing case. These must become a looping default `Animation`, not only retargetable clips.

---

## 10. Particle modifier addressing

`OPEN`

`NiPSysEmitterCtlr` links carry an empty `propType` but a `ctrlID` naming a `NiPSysModifier`
within the particle system:

| ctrlID | links |
|---|---:|
| `NiPSysBoxEmitter:0` | 3,035 |
| `NiPSysMeshEmitter:0` | 566 |
| `NiPSysCylinderEmitter:0` | 453 |

Structurally identical to property addressing with a different key. Whatever is built for
`(node, propType, ctrlID)` should generalise to `(node, modifierName, ctrlID)` rather than being
material-specific.

---

## 11. Multi-file assembly (the actor path)

`SETTLED` (contract) · ragdoll mapping `OPEN`

### 11.1 Contract

| | |
|---|---|
| **NifServer has no humanoid, actor, creature or equipment entry point.** | One NIF in, one honest Godot representation out. |
| Merging is the caller's responsibility | If a result needs combining with other files, the assembler does it. |
| Basis | No single NIF contains an actor. An actor is a merge of five or more files, and every file in it is a valid standalone return. |

### 11.2 What an actor merges

| source | contributes | skin |
|---|---|---|
| `skeleton.nif` (`NPC_.MODL`, shared by both genders) | bone hierarchy, ragdoll, bone LOD | none |
| body parts (RACE `NAM0`/`FNAM`/`NAM1`/`MNAM` `INDX` blocks) | upperbody, hands, feet | skinned, flat bone list |
| head parts | head, eyes, mouth, hair | unskinned, facial-head space |
| armor / equipment | per-slot, gendered meshes | skinned, or unskinned accessory |
| weapon | held mesh | usually unskinned, bone-attached |
| TRI / EGM | morph deformation | not NIF data |

### 11.3 `skeleton.nif` is not only bones

`meshes/characters/_male/skeleton.nif`, 388 blocks:

| block | count | role |
|---|---:|---|
| `NiNode` + `BSFadeNode` root | 66 | the bone hierarchy |
| `NiTransformController` | 65 | one per bone |
| `bhkRigidBody` / `bhkCapsuleShape` / `bhkBlendCollisionObject` | 18 each | **ragdoll bodies** |
| `bhkMalleableConstraint` / `bhkRagdollConstraint` | 14 / 3 | **ragdoll joints** |
| `NiStringExtraData` | 64 | per-bone metadata |
| `NiTriShape` `HeadAnims:0` + `NiGeomMorpherController` + `NiMorphData` | 1 each | morph-target mesh |
| `NiBSBoneLODController`, `BSBound` | 1 each | bone LOD, bounds |

A generic per-file return already produces the ragdoll and the morph mesh. This is the first place
the collision-flattening and joint questions in [§2.3](#23-exception-transform-bearing-non-nodes)
have to be answered.

### 11.4 Skinned parts carry a bone name list, not a skeleton

Measured across all 1,038 skinned NIFs (`tools/nif_xcheck/skin_bone_shape.cpp`):

| bone-list shape | files |
|---|---:|
| **FLAT** — no bone is the child of another bone | **892 (86%)** |
| NESTED — real hierarchy | 135 |
| MIXED — several bone roots | 11 |

| | |
|---|---:|
| bone references total | 20,279 |
| **not parented to another bone** | **19,945 (98%)** |
| files whose every bone sits at depth 1 | 887 |

The 135 nested files are almost entirely 2-bone `go.nif` ground-drop meshes.

**Consequence:** a skinned body or armor NIF contains a bone *name list* plus bind transforms, not a
skeleton. Building a `Skeleton3D` from `upperbody.nif` alone yields a flat 26-bone skeleton that is
geometrically wrong. **NifServer never resolves a skin into a `Skeleton3D`.**

### 11.5 Construction flags replaced by file content

| `mesh_resolver.gd` signal today | replacement |
|---|---|
| empty `skin_entries` ⇒ "this IS the skeleton" | derivable: file has nodes and no skin data |
| `head_part_specs` vs `body_part_model_paths` | derivable: whether the part's geometry is skinned |
| `part_type`, gender, slot, addon model, biped conflicts | not NIF data — ESM-level, stays in the caller |
| head-accessory filename heuristics | not NIF data |
| `face_gen` | external data, applied after construction |

Only the first two are NIF questions, and both are answerable from content.

### 11.6 What NifServer must expose for a merge to be possible

| | |
|---|---|
| bone **names**, verbatim | the merge key; see [§6](#6-node-names-and-godot-mapping) |
| bind transforms per skinned mesh | so a part can rebind onto a foreign skeleton |
| whether each geometry is skinned | selects rebind vs bone-attach |
| the node tree with transforms | unskinned parts compose by transform |
| the file root transform | parts compose against the shared rig |

Assembly order in the caller: build one `Skeleton3D` from `skeleton.nif`'s node tree → rebind each
skinned part's bone names onto it → attach each unskinned head part under a `BoneAttachment3D` on
`HeadAnims` (falling back to `Bip01 Head`) → apply morphs last.

"Bind to an external skeleton" is an **assembly parameter of the caller**, not a NIF flag. NifServer
stays flag-free; the assembler legitimately has modes.

#### Unresolved skins are native to Godot

A skin needs a bone index and a skeleton path to render. Both are properties of the rig it is bound
to, so NifServer supplies neither — it binds by **name** and leaves resolution to registration time.

| step | who | what |
|---|---|---|
| 1 | NifServer | `MeshInstance3D` + `Skin` built with `add_named_bind(bone_name, bind_pose)`; `skeleton` left unset |
| 2 | caller | reparent the mesh under its `Skeleton3D`, set `mi.skeleton` |
| 3 | Godot | resolves every named bind against that skeleton's bone names |

The bone index is never stored. It is derived per-skeleton at registration, which is what a mesh that
binds to a different rig on each equip requires.

Verified on Godot 4.7.1 (`tools/godot_named_bind_check/`): a valid name registers silently, and a
missing one raises `Skin bind #0 contains named bind 'NoSuchBone' but Skeleton3D has no bone by that
name.` — so a bone-name mismatch fails loudly, rather than the silent `find_bone() == -1` corruption
the manual binding path in `mesh_resolver.gd` risks.

### 11.7 Construction note

A code-built `Skeleton3D` requires `reset_bone_poses()`, or every bone renders pinned to the world
origin.

### 11.8 Open items

| # | Question |
|---|---|
| ~~1~~ | **Closed:** `PhysicalBone3D` under a `PhysicalBoneSimulator3D`, built always and inert until `physical_bones_start_simulation()`. Discriminated by `bhkBlendCollisionObject` (60 files, 56 named `skeleton*.nif`), never by presence of constraints — 164 files carry a constraint without one. |
| 2 | `NiBSBoneLODController` (bone LOD) has no Godot equivalent. |
| 3 | Creature assembly has no RACE-equivalent ESM-declared body mesh path — only a same-folder naming convention. |

---

## 12. Open questions

| # | Question | Blocks |
|---|---|---|
| 1 | Does NifServer return a tree, or a tree + resource side-car? Skinning does **not** force the question — unresolved skins are expressible in a plain node tree ([§11.6](#116-what-nifserver-must-expose-for-a-merge-to-be-possible)). What remains is per-node source-property identity for the §9 fan-out, which node metadata covers. | API shape |
| 2 | Where does collision live — one body per `bhkCollisionObject` parented to the owning node with shapes flattened, or shapes as siblings? | §2.3 |
| 3 | Are nameless `BSMultiBoundNode` wrapper transforms identity? Decides the ~4,100-node collapse. | §5 |
| 4 | What are the 280 palette mismatches' 54 "unrelated name" cases specifically? | §8 |
| 5 | How often are non-property blocks multiply-referenced? Needs full link-graph parsing (nifly-based tool, not header parsing). | §2.4 |

---

## 13. Tooling

All scans are standalone Python under `tools/` — they implement BSA v103/104 reading and NIF
header parsing directly, with no build step and no dependency on the Godot extension.

| script | reproduces | purpose |
|---|---|---|
| `tools/nif_scan_common.py` | — | shared BSA reader, NIF header parser, nifly inheritance extraction |
| `tools/nif_type_census.py` | §1 | per-type file/block counts across the corpus |
| `tools/nif_vertex_color_scan.py` | §4 | geometry-block vertex-colour scan |
| `tools/nif_kf_target_classes.py` | §6, §7 | KF target classification, skeleton comparison, name legality |
| `tools/nif_anim_targets.py` | §7, §9.1, §10 | controlled-link key-space histograms |
| `tools/nif_object_palette_audit.py` | §8 | palette entries vs the blocks they reference |
| `tools/nif_property_addressing.py` | §9 | property sharing, multiplicity, owned controllers |
| `tools/nif_xcheck/` (C++) | §2.4, §3, §11.4, §14 | independent re-derivation through nifly; `avobject_shape.cpp` emits the node map profile, `prune_candidates.cpp` the pruning reward, `skin_bone_shape.cpp` the bone-list shape |

`tools/godot_named_bind_check/` is a headless Godot script confirming named skin-bind
resolution (§11.6).

Each writes JSON to stdout; the census takes an output path argument. Full corpus run is a few
seconds per script.

### Parser gotchas encoded in `nif_scan_common.py`

Each of these silently corrupts block offsets rather than raising, so they are documented at the
point of use:

| field | rule |
|---|---|
| `numBlockTypes` | `uint16`, not `uint32` |
| Bethesda stream-version branch | applies from user version **10**, not 11 (six shipped 20.0.0.4 files are user 10) |
| `NiAVObject::flags` | `uint16` when BS stream version <= 26, `uint32` otherwise |
| `NiAVObject::velocity` | **absent** above file version 4.2.2.0, so never present in FO3/FNV |
| `NiAVObject::propertyRefs` | present only while BS stream version <= 34 |
| export strings (`creator`, `exportInfo*`) | byte-length prefix **includes** the trailing null |

### Self-validation

Two independent checks confirm the block-offset arithmetic rather than assuming it:

- geometry block totals from the deep walk match the header census exactly (67,972)
- all 1,164 object-palette walks terminate precisely on their block boundary (zero drift)

### Data caveats

| scan | anomalies |
|---|---|
| type census | 0 failures / 25,760 files |
| vertex colour | 1 file rejected / 20,444 |
| KF target classes | 1 NIF + 5 KF rejected / 25,760 |
| animation targets | 5 files rejected / 25,760 |
| palette audit | 1 file rejected / 20,746 |
| property addressing | 6 files rejected / 25,760 |

Rejects are individual files whose deeper block walk failed; all are below 0.03% and none affect
the conclusions above.

---

## 14. Verification against nifly

`SETTLED`

Every figure above was first measured with the standalone Python scanners, then re-derived through
nifly's own parsed object model — the same library NifServer will use — over the same 25,760 files.

| nifly result | |
|---|---:|
| files loaded | **25,760 / 25,760** |
| `Load()` errors or invalid headers | **0** |
| exceptions thrown | **0** |
| blocks that failed to instantiate (`GetBlock<NiObject>` null) | **0** |
| distinct block types | **160** |

**Per-type census: zero mismatches.** All 160 types agree with the Python census on both file count
and block count.

### Deep-walk agreement

| figure | Python | nifly |
|---|---:|---:|
| files with vertex colours | 12,408 | **12,408** |
| geometry blocks / with vertex colours | 67,972 / 46,958 | **67,972 / 46,958** |
| coloured vertices | 23,754,470 | **23,754,470** |
| palette blocks / entries / matches / mismatches / null refs | 1,164 / 26,022 / 25,410 / 280 / 332 | **identical** |
| palette entries with an empty name | 0 | **0** |
| mismatched palette names found on another block | 0 | **0** |
| links carrying a `propType` | 8,359 | **8,359** |
| distinct property triples | 11 | **11** |
| property refcount and per-node multiplicity histograms | see §9.2–9.3 | **identical** |
| properties owning a controller | see §9.5 | **identical** |

### Divergences found, and what they were

| figure | Python | nifly | cause |
|---|---:|---:|---|
| controlled links | 291,472 | 291,837 | the 365 string-palette links in §7.4, which the Python parser rejected |
| sequences | 7,478 | 7,483 | same 5 files |
| links with blank `nodeName` | 0 | 365 | same 5 files |
| files with geometry | 20,444 | 20,445 | one file the Python deep walk rejected |
| nameless `NiAVObject` blocks | 9,214 | 9,213 | one block classified as `NiAVObject` by inheritance table but not by nifly's RTTI |

The first three are one finding — the second addressing mechanism (§7.4) — which the Python scans
missed by silently excluding the files they could not parse. The remaining two are single-block
rounding and change nothing.

**Conclusion:** the census and structural conclusions are independently reproduced by nifly. The
one substantive gap the cross-check closed is §7.4, which is now a stated loader requirement.

**Method note:** the risk here was never arithmetic, since every Python field layout was transcribed
from nifly's own `Sync()` methods. The risk was *silent exclusion* — files the Python parser
rejected were dropped from the denominator rather than failing loudly, which is exactly how the
string-palette files hid. Future scans should treat a parse rejection as a finding, not an error rate.
