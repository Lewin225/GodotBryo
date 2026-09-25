# Current NIF Node Handling Inventory

This is an inventory of what the current native reader and old GDScript resolver actually handle. It is
not yet the NifServer scene-hierarchy specification. In particular, the presence of a NIF `NiNode`-family
block does not by itself mean that the new server should create a Godot `Node3D` for it.

## The important distinction

The current pipeline has three different concepts which must not be conflated:

1. A NIF block that carries authored data or behavior.
2. A NIF object that can own a mesh, collision, or controller.
3. A Godot node that must exist in the returned scene tree.

The existing dynamic resolver often uses a generic `Node3D` for scene-node entries, but that is an
implementation convenience, not proof that every source block requires a Godot node.

## Currently handled renderable content

| NIF content | Current handling | Godot result |
|---|---|---|
| `NiShape` descendants returned by nifly's `GetShapes()` | Vertex positions, normals, UVs, indices, vertex colors, shader/material flags, texture paths, and local/root-relative transforms are extracted. | `MeshInstance3D` with an `ArrayMesh` in the ordinary node path. |
| `NiTriShape` | Handled through the generic `NiShape`/nifly shape path. | `MeshInstance3D`. |
| `NiTriStrips` | Handled through the generic `NiShape`/nifly shape path and represented as triangle indices. | `MeshInstance3D`. |
| `BSTriShape` | Handled through nifly's generic shape access, including its skin-weight path when applicable. | Ordinary or skinned `MeshInstance3D`, depending on the construction path. |
| Editor-marker mesh names such as `EditorMarker*` | Skipped at runtime; retained for editor inspection. | No runtime mesh node. |

The current resolver can also send static geometry to `DirectGeometryBatch`, but that is a separate
placement path and is not part of the NifServer `Node3D` return contract.

## Current transform-bearing objects

| NIF content | Current handling | Current limitation / question |
|---|---|---|
| Non-root `NiAVObject` | Native extraction records its name, local transform, and parent index. | The old dynamic path creates a generic `Node3D` for each scene-node entry. The new server must decide which entries truly need nodes. |
| `NiNode` | Its parent/child relationship and local transform can be represented by the generic scene-node path. | No distinct `NiNode` behavior is implemented beyond transform hierarchy. |
| `NiShape` as an `NiAVObject` | Its owning scene-node index is used to place the mesh under the corresponding dynamic node. | The source shape object and the visual `MeshInstance3D` are separate concepts. |
| NIF root object | Deliberately excluded from the native `scene_nodes` list. | The returned wrapper/root still needs an explicit NifServer convention. |

## Current collision ownership

Collision is not limited to renderable shapes. The native reader walks every `NiAVObject` for a collision
reference, because collision is commonly attached to a parent `NiNode` rather than the visible mesh.

Currently extracted collision forms are:

- `bhkPackedNiTriStripsShape` → triangle mesh
- `bhkBoxShape` → box
- `bhkSphereShape` → sphere
- `bhkCapsuleShape` → capsule
- `bhkConvexVerticesShape` → convex hull

Collision descriptors retain the owning scene-node index and, where present, the authored rigid-body
descriptor. Unsupported composite/phantom forms are detected as unhandled rather than fabricated into a
different shape.

## Current skinning and morph data

These are currently extracted as data associated with a mesh; they are not represented by a generic
`Node3D` per source block.

| NIF content | Current handling | Godot construction |
|---|---|---|
| `NiSkinInstance` / `BSDismemberSkinInstance` with `NiSkinData` and `NiSkinPartition` | Bone names, bind transforms, skin transform, four-slot vertex indices/weights, and body-part IDs are extracted. | A separate `Skeleton3D` plus skinned `MeshInstance3D` path in the old resolver. |
| `NiGeomMorpherController` + `NiMorphData` | Per-target vertex deltas and available weight tracks are extracted. | Blend shapes and morph animation are constructed by the old skinned path. |

The current native skin path is shape-oriented: it associates skin data with the owning `NiShape`, while
the skeleton hierarchy is reconstructed from the relevant scene-node entries. This does not mean every
scene-node entry needs to become an ordinary Godot `Node3D`; some entries may only be needed as skeleton
bones or bind-pose data.

## Current animation data

The native reader extracts animation as plain data:

- `NiControllerManager`-owned `NiControllerSequence` blocks
- top-level `NiControllerSequence` blocks, including standalone KF-style files
- transform tracks from supported transform interpolators
- compressed `NiBSplineTransformInterpolator` tracks
- float tracks used by supported non-transform controllers
- bool tracks currently consumed as visibility tracks
- direct controllers attached to individual `NiAVObject` instances

The old resolver then creates `AnimationPlayer` resources on the main thread and binds tracks either to
ordinary dynamic scene nodes or to `Skeleton3D` bones. The controller/interpolator blocks themselves are
not one-for-one Godot nodes.

## Recognized by nifly but not currently given distinct Godot semantics

The vendored NIF model includes additional `NiNode`-family or geometry types, including:

- `NiBSParticleNode`
- `NiBillboardNode`
- `NiSwitchNode`
- `NiLODNode`
- `NiParticles`
- `NiRotatingParticles`

The current resolver does not implement their specialized runtime behavior as separate Godot node types.
Where they pass through generic `NiAVObject`/shape handling, only the data that generic path understands is
preserved. Billboard orientation, switch selection, NIF LOD selection, and particle simulation are not
established NifServer features merely because nifly can parse the block class.

## Open NifServer questions left by this inventory

- Which `NiAVObject` entries must become ordinary `Node3D` instances for transform animation?
- Which entries exist only to provide parent transforms for a mesh or collision shape?
- Which entries become `Skeleton3D` bones instead of ordinary nodes?
- How are shape-owned and parent-owned collision descriptors attached in full and flattened modes?
- Which specialized node semantics, if any, are required for v1 rather than preserved as diagnostics?

## Source locations

- Native scene-node extraction: `native/src/nif/nif_loader.cpp`
- Native result structures: `native/src/nif/nif_types.h`
- Godot wrapper accessors: `native/src/nif/nif_reader_gd.h`
- Existing raw mesh/collision extraction: `project/gamebryo/mesh_resolver.gd`
- Existing dynamic hierarchy construction: `project/gamebryo/mesh_resolver.gd`, `populate_dynamic_children()`
- Existing skeleton construction: `project/gamebryo/mesh_resolver.gd`, `populate_skeleton()`
