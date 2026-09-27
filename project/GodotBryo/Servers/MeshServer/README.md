# MeshServer

**Not built. This folder holds the decision, not an implementation.**

Mesh caching currently belongs to NifServer. Nothing else in the project
consumes a mesh, and a mesh's identity is NIF-derived, so a separate server
would own something only one caller asks for.

---

## Why not now

A server earns its place when two callers need the same primitive and neither
owns the format it comes from. That is the case TextureServer exists for:
NifServer's material builder, UI and terrain all want textures, and a texture path
means something without a NIF in the picture.

Meshes have one consumer. NifServer asks for them while building a tree, and a
mesh's key is a NIF path plus a shape index — meaningless to anything that is
not reading a NIF.

Splitting it out now would add:

- **Two owners for mesh identity.** The skinned and non-skinned builds of one
  shape are different meshes, and the key has to say so. The legacy resolver
  learned this the hard way and kept `_skin_mesh_cache` separate from
  `_mesh_cache`, "since these surfaces carry `ARRAY_BONES`/`ARRAY_WEIGHTS` a
  non-skinned build of the same submesh must never pick up."
- **A second parse**, unless the caller hands over the `NifSource` it already
  has, which couples the two servers anyway.
- **Cache coherence** between a server that holds meshes and a server that
  builds the trees they sit in.

---

## What it would be, if it is built

The trigger is a second consumer: UI, or a caller that wants one arbitrary
submesh without building a tree.

Contract shaped like TextureServer's — `warm()` and `request()`, resident
returns immediately, in-flight attaches a waiter, cold queues one. That shape
requires the server to be able to produce on a miss, so it would read through
`NifSource` (the native reader) rather than NifServer (the tree builder).
NifServer would then become a consumer of it rather than its owner.

Keying is the part to get right first: a NIF path, a shape index, and a variant
that distinguishes a skinned build from a non-skinned one.

---

## Why the cache matters wherever it lives

Godot batches on **RID identity, not content**. The draw-list sort key is built
from `p_mesh.get_local_index()` and the material's own index
(`render_forward_clustered.cpp`), and consecutive elements coalesce into one
instanced draw only when those keys match exactly. Two byte-identical
`ArrayMesh` objects are two RIDs and therefore two draw calls.

So caching is a rendering requirement, not an optimisation. `Node.duplicate()`
shares resource references rather than copying them — object-typed properties
are assigned, not duplicated, unless flagged `PROPERTY_USAGE_ALWAYS_DUPLICATE`,
which nothing on `MeshInstance3D`, `CollisionShape3D` or `Skeleton3D` is — so
one cached build plus N duplicates gets the batching that N independent builds
cannot.

NifServer does not cache yet. See
[`Plans/Completed Plans/NifServer/Implementation/outstanding_issues.md`](../../../../Plans/Completed%20Plans/NifServer/Implementation/outstanding_issues.md)
#11.

---

## Related

[`MaterialServer`](../MaterialServer/README.md) is the same question for
materials, with a stronger case: UI needs materials with no NIF involved, which
is the two-caller test meshes fail. The batching findings that constrain both —
instance uniforms, the shader-versus-material cost tiers, and why
`material_override` is duplication by another name — are recorded there.

**One case sits outside all of this.** FaceGen deformation is per-NPC, so head
geometry is a unique mesh by definition and can never come from a shared cached
tree, however the caching is arranged.
