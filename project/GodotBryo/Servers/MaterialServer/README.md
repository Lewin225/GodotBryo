# MaterialServer

**Not built. This folder holds the decision, not an implementation.**

NifServer builds a `StandardMaterial3D` per shape, inline, owned by nothing else.

---

## The case is stronger than MeshServer's

A server earns its place when two callers need the same primitive and neither
owns the format it comes from. That is why TextureServer exists — NifServer's
material builder and terrain both want textures, and a texture path means
something with no NIF in the picture.

Materials pass that test. UI will want materials with no NIF involved. Meshes do
not: a mesh's key is a NIF path plus a shape index, meaningless to anything not
reading a NIF, which is why [`MeshServer`](../MeshServer/README.md) was declined.

What is missing is the second caller *today*. When UI material loading lands,
this is the point to build it rather than growing a second cache there.

---

## What it would be

**It hands out shared materials keyed by structural identity, and per-instance
variation is explicitly not its problem.** That is a sharper contract than "a
cache with a copy path", and it means nobody mutates a MaterialServer material —
callers vary the instance instead.

That distinction matters more here than for textures. Nobody writes to a cached
`ImageTexture`. A `StandardMaterial3D` gets tinted, faded and re-alpha'd, and
anything doing that to a shared instance changes every other user of it. Copying
TextureServer's contract verbatim would inherit a hazard textures do not have.

**It cannot be enforced.** `core/io/resource.h` has no read-only, freeze or const
mechanism, so a server cannot stop a caller mutating what it handed out. The rule
is a convention, which argues for making ownership obvious at the call site —
`shared(key)` is harder to misuse carelessly than `get(key)`.

The project's existing per-instance variation already avoids the hazard without
anyone deciding to: `esm_humanoid_actor.gd` builds a *new* material and assigns it
through `material_override`, leaving the shared one untouched. That pattern is
correct but costs the instanced draw for that instance — fine for a handful of
NPCs, not for a few hundred objects.

---

## Why sharing is a rendering requirement

Godot batches on **RID identity, not content**. Consecutive draw-list elements
coalesce into one instanced draw only when their sort keys match exactly, and
that key is built from the mesh RID's index and the material RID's index
(`render_forward_clustered.cpp`). Two materials with identical parameters are two
RIDs and do not batch.

**A material is an instance of a shader, and the renderer models it that way.**
`shader_id` and `material_id` are separate sort-key fields, ordered coarsest
first — the source comment says the order exists "to reduce the amount of
rebinding of shaders, materials, and geometry". So a unique material is one tier
of cost, not a cliff:

| case | cost |
|---|---|
| same shader, same material, same mesh | coalesces into one instanced draw |
| same shader, different material | no coalesce; sorted adjacent, uniform-set rebind |
| different shader | pipeline rebind, worst |

Runtime material duplication therefore costs the instanced draw but keeps the
pipeline bound. Negligible for a handful of UI panels, decisive for a few hundred
world objects.

---

## Animated materials are the constraint

NIF controller sequences target material properties, not only node transforms.
Measured across the shipped `.nif` corpus:

| | |
|---|---:|
| files with sequences | 1,153 |
| …with at least one property-targeted link | **582** |
| …**property-only** — no transform track at all | **271** |
| links: transform / property | 25,717 / 5,295 |

Exactly **11** distinct `(propType, ctrlType, ctrlID)` triples exist corpus-wide,
a closed and hand-writable mapping table:

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

`meshes/nvdlc04/dungeons/utemple/nvdlc04uskydome.nif` is the shape of it: a
266-second looping `Idle` whose three controlled blocks are two scrolling UV
transforms and a `SELF_ILLUM` colour curve, and not one transform track.

**An AnimationPlayer track pointed at a material is in-place mutation, running
every frame.** That is the hazard above, arriving through animation rather than
through a caller writing to a property. It does not exist yet only because
property tracks are unimplemented — see
[`outstanding_issues.md`](../../../../Plans/NifServer/Implementation/outstanding_issues.md)
#5. Implementing them creates it across 582 files.

So sharing is decided per tier, not per server:

| tier | sharing |
|---|---|
| static material (the majority) | shared, batches, no custom shader |
| animated, few instances (one sky) | per-instance material; it costs an instanced draw that was never going to happen |
| animated, many instances | must be instance uniforms, therefore `ShaderMaterial` |

Two of the eleven — `TT_ROTATE` and `BSRefractionFirePeriodController` — have no
`StandardMaterial3D` equivalent at all, so they force a custom shader regardless
of what sharing decides.

**Unmeasured, and it decides tier two versus tier three:** how many instances of
each animated model a cell actually places. That is REFR placement data, not NIF
content.

---

## Per-instance variation

**Only instance uniforms vary a material per instance without breaking
batching.** They live in the instance data rather than the material, so
`material_id` is unchanged and the coalesce still fires. Two constraints:

- `MAX_INSTANCE_UNIFORM_INDICES = 16` per shader
  (`servers/rendering/shader_language.h`).
- `BaseMaterial3D` declares **none** — `scene/resources/material.cpp` contains
  zero `instance uniform` declarations. They require a `ShaderMaterial` with a
  hand-written shader, so per-instance variation and staying on
  `StandardMaterial3D` are mutually exclusive. Dispatching on the NIF's own
  `shader_type` is the enabler.

`material_override` does not help: it replaces the material for that instance, so
a unique override is a unique `material_id` and is duplication by another name.
It only pays when the override itself is shared by a group.

Which suggests splitting by axis of variation rather than picking one mechanism:

| varies | mechanism |
|---|---|
| per instance, cheap and numeric (tint, fade, glow, damage blend) | instance uniform, within the 16-slot budget |
| per group (faction colour, weather state) | one shared material per group, batches within it |
| structurally (different textures, different blend mode) | genuinely a different material |

---

Related: [`MeshServer`](../MeshServer/README.md) for the mesh side of the same
question, and
[`outstanding_issues.md`](../../../../Plans/NifServer/Implementation/outstanding_issues.md)
#11 for NifServer's missing cache.
