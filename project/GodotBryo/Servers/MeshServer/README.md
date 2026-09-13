# MeshServer

**Not built. This folder holds the decision, not an implementation.**

Mesh caching currently belongs to NifServer. Nothing else in the project
consumes a mesh, and a mesh's identity is NIF-derived, so a separate server
would own something only one caller asks for.

---

## Why not now

A server earns its place when two callers need the same primitive and neither
owns the format it comes from. That is the case TextureServer exists for:
NifServer's material builder and terrain both want textures, and a texture path
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
[`Plans/NifServer/Implementation/outstanding_issues.md`](../../../../Plans/NifServer/Implementation/outstanding_issues.md)
#11.

---

## Related: materials, and per-instance variation

MaterialServer is a **different** question with a stronger case: UI needs
materials with no NIF involved, which is the two-caller test MeshServer fails
and TextureServer passes. It is not blocked on any of the above.

The findings below came out of sizing that question and are recorded here
because they constrain any caching decision on either side.

**A material is an instance of a shader, and the renderer agrees.** `shader_id`
and `material_id` are separate fields in the draw-list sort key, ordered
coarsest first — the source comment says the order exists "to reduce the amount
of rebinding of shaders, materials, and geometry". So a unique material is one
tier of cost, not a cliff:

| case | cost |
|---|---|
| same shader, same material, same mesh | coalesces into one instanced draw |
| same shader, different material | no coalesce; sorted adjacent, uniform-set rebind |
| different shader | pipeline rebind, worst |

Runtime material duplication therefore costs the instanced draw but keeps the
pipeline bound. Negligible for a handful of UI panels, decisive for a few
hundred world objects.

**Only instance uniforms give per-instance variation without breaking
batching.** They live in the instance data rather than the material, so
`material_id` is unchanged and the coalesce still fires. Two constraints:

- `MAX_INSTANCE_UNIFORM_INDICES = 16` per shader
  (`servers/rendering/shader_language.h`).
- `BaseMaterial3D` declares **none** — `scene/resources/material.cpp` contains
  zero `instance uniform` declarations. They require a `ShaderMaterial` with a
  hand-written shader, so per-instance variation and staying on
  `StandardMaterial3D` are mutually exclusive. Dispatching on the NIF's own
  `shader_type` is the enabler.

`material_override` does not help: it replaces the material for that instance,
so a unique override is a unique `material_id` and is just duplication by
another name. It only pays when the override itself is shared by a group.

This suggests splitting by axis of variation rather than picking one mechanism:

| varies | mechanism |
|---|---|
| per instance, cheap and numeric (tint, fade, glow, damage blend) | instance uniform, within the 16-slot budget |
| per group (faction colour, weather state) | one shared material per group, batches within it |
| structurally (different textures, different blend mode) | genuinely a different material |

Which gives MaterialServer a sharper contract than "a cache with a copy path":
it hands out shared materials keyed by structural identity, and per-instance
variation is explicitly not its problem. Nobody mutates a MaterialServer
material; callers vary the instance.

**One case sits outside all of this.** FaceGen deformation is per-NPC, so head
geometry is a unique mesh by definition and can never come from a shared cached
tree, however the caching is arranged.
