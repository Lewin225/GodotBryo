# `mesh_resolver.gd` construction audit

This audit records the code-path, duplicate-construction, and special-case review of `project/gamebryo/mesh_resolver.gd`. It is an identification report only; no implementation changes are implied.

## Construction paths

- Static flattened NIF construction:
  - `resolve_raw_geometry()` → `build_geometry_entries()` → `_build_mesh_entries()`.
  - `populate_mesh_children()` creates one `MeshInstance3D` per submesh.
  - `populate_collision_children()` creates a separate collision body.
  - Used by ordinary visual objects, lights, keys, rigid-body items, terrain-adjacent paths, and accessories.

- Dynamic hierarchical construction:
  - `populate_dynamic_children()`.
  - Rebuilds the NIF `SceneNode` hierarchy as `Node3D` nodes.
  - Attaches meshes to owning nodes with identity transforms.
  - Builds collision bodies grouped by owning NIF node.
  - Used by doors, animated fallback objects, and unskinned weapons.

- Standalone skinned-NIF construction:
  - `populate_skeleton()`.
  - Creates `Skeleton3D`, bones, `Skin`, skinned meshes, morph animations, and embedded animations.
  - Used for skinned props, flags, creatures/body meshes, and fallback skinned objects.

- Humanoid multi-file construction:
  - `populate_humanoid_skeleton()`.
  - Loads a separate skeleton NIF, body-part NIFs, head parts, facial attachments, FaceGen geometry, TRI morphs, and equipment.
  - The incremental equivalents are `begin_humanoid_skeleton()`, `populate_humanoid_body_part()`, `populate_humanoid_head_part()`, and `finish_humanoid_morphs()`.
  - This is effectively a second public construction API beside the monolithic one.

- Unskinned head-part construction:
  - `_populate_head_part_meshes()`.
  - Independently rebuilds mesh, material, morph, FaceGen, TRI, transform, metadata, and `MeshInstance3D`.
  - Does not use `build_geometry_entries()` or the normal mesh cache.

- Skinned submesh construction:
  - `_populate_skinned_mesh_instances()`.
  - Independently rebuilds mesh/material/node assembly instead of using `_build_mesh_entries()`.
  - Uses a separate `_skin_mesh_cache`.

- Equipment construction:
  - `populate_equipment()` interprets armor slots, biped conflicts, gender models, addon models, weapon models, attachment types, and metadata.
  - `_populate_weapon_model()` has separate skinned, dynamic, collision-removal, and embedded-animation behavior.
  - `_populate_unskinned_equipment()` identifies head accessories through filename heuristics and attaches them to bones.

- Item physics construction:
  - `populate_rigid_body_children()` builds a movable `GamebryoRigidBody`, invents a mass conversion, configures CCD/contact monitoring/freezing, then reuses static mesh construction.
  - `populate_authored_rigid_bodies()` builds one or more rigid bodies from authored NIF physics descriptors, including physics materials, damping, gravity, body metadata, body assignment, and fallback body creation.

- Direct RID/batched construction is duplicated outside the resolver:
  - `_construct_direct()` in `object_registry.gd` builds geometry through the resolver, then feeds `DirectGeometryBatch`.
  - Node construction uses the same resources but a different transform and visibility model.

## Duplicate mesh/resource construction

1. `_build_mesh_from_raw()` is the common base builder.

2. `_build_mesh_entries()` wraps it for normal static meshes.

3. `_build_skinned_mesh_from_raw()` independently calls `_build_mesh_from_raw()`, then reconstructs an `ArrayMesh` to add bones and weights.

4. `_populate_head_part_meshes()` directly calls `_build_mesh_from_raw()`, applies morphs/materials/FaceGen/TRI, and creates nodes manually.

5. `_populate_skinned_mesh_instances()` repeats the same sequence: resolve raw geometry, build mesh, apply morphs, build material, optionally apply FaceGen, optionally apply TRI, create `MeshInstance3D`, assign metadata, create `Skin`.

6. `build_geometry_entries()` and the individual population functions can each resolve/build when the optional `geometry` argument is omitted. This gives several implicit “resolve and construct” entry points.

7. `populate_rigid_body_children()` calls `populate_mesh_children(body, null, "", geometry)`, overloading the static visual API with a prebuilt-geometry/null-NIF mode.

8. `populate_authored_rigid_bodies()` repeats that same visual attachment behavior, but only on the first rigid body.

9. Normal meshes are cached by `model_path#submesh`; skinned meshes use a separate cache; FaceGen/TRI-modified final meshes are intentionally rebuilt per actor. These are separate construction identities for the same source submesh.

## Duplicate factory paths outside the resolver

`object_registry.gd` contains synchronous versions parallel to the threaded versions:

- `_instantiate_visual()` ↔ `_construct_visual()`
- `_instantiate_dynamic()` ↔ `_construct_door()` / `_construct_animated_visual()`
- `_instantiate_skinned()` ↔ `_construct_skinned_visual()`
- `_build_light()` ↔ `_construct_light()`
- `_build_item()` ↔ `_construct_item()`
- `_build_scol()` ↔ `_construct_scol()`

The resolver therefore supports both the older synchronous factory pipeline and the newer raw-resolve/main-thread-commit pipeline.

## Collision special cases

`_resolve_raw_collision()` and `_build_collision_shapes()` support:

- triangle mesh
- convex hull
- box
- sphere
- capsule
- fabricated fallback AABB
- authored collision ownership by NIF scene node
- authored physics-body association
- capsule axis reconstruction
- forced two-sided triangle collision
- no-collision preservation when the NIF has no authored collision data

Collision is then attached through three separate paths:

- `populate_collision_children()`: one body for the object.
- `populate_dynamic_children()`: one body per owning NIF node.
- Rigid-body methods: collision shapes distributed among movable bodies.

## Material and texture special cases

`_build_material_from_raw()` contains a full material policy layer:

- diffuse, normal, and glow texture slots
- texture decode and GPU-upload caching
- DXT1 alpha decompression variants
- alpha blending
- alpha scissor
- authored blend-function conversion
- vertex-color-as-albedo
- unlit materials
- double-sided materials
- dedicated no-lighting falloff shader
- XEMI tinting through a second material override path
- cache-key construction for all of the above
- null-material behavior for textureless geometry

This is substantially more than “convert the NIF’s material.”

## Animation construction

The resolver also owns several unrelated animation systems:

- Embedded NIF sequence conversion: `populate_animation_player()` and `_build_sequence_animation()`.
- Direct controller conversion: `populate_direct_controller_player()`.
- External node/KF animation: `populate_external_node_animations()`.
- Skeleton animation: `_populate_skeleton_animation_player()`.
- Locomotion/KF animation: `populate_locomotion_animations()` and `populate_actor_kf_animations()`.
- Animation-tree assembly: `populate_locomotion_tree()`.
- Morph animation: `_populate_morph_animation_player()`.
- Animation disk caching and target signatures.
- Interpolation conversion and per-axis rotation resampling.
- Automatic `SpecialIdle` and looping-animation playback.

## Data-specific special cases

The resolver contains hardcoded behavior for:

- EditorMarker submesh filtering.
- Head NIF identification.
- Head-part identification.
- Facial-morph model identification.
- Hair `hat`/`nohat` submesh variants.
- FaceGen EGM parsing.
- TRI parsing.
- Humanoid skeleton assembly.
- External bone attachments.
- Weapon attachment fallback bones.
- Head accessory filename classification.
- XSRF/XSRD distant objects.
- Optional `_lod.nif` companions.
- LOD visibility ranges.
- Terrain texture loading through `load_texture()`.
- Door sound loading through `load_sound()`.
- Bethesda-to-Godot transform conversion.
- DirectGeometryBatch world transforms.
- Inventory-weight-to-mass conversion.
- Authored-vs-fabricated physics bodies.

## Main architectural finding

The intended boundary—“load NIF data and return a Godot-converted representation”—is crossed in multiple directions:

- raw binary resolution
- decoded image ownership
- GPU resource creation
- material policy
- mesh construction
- node hierarchy construction
- skeleton construction
- skin binding
- morph application
- collision construction
- rigid-body construction
- animation import/playback
- equipment interpretation
- actor assembly
- sound loading
- placement transform policy

The largest duplication is between normal static mesh construction, dynamic hierarchy construction, unskinned head construction, skinned construction, humanoid construction, equipment construction, synchronous registry construction, and threaded registry construction.
