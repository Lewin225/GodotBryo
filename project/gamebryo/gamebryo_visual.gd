class_name GamebryoVisual
extends GamebryoObject

## Layer for base records with MODL: has renderable geometry. Composition
## shape (phases/1/architecture.md): MeshInstance3D children built from the
## resolved NIF, one per submesh, plus (phases/1/02-collision-extraction.md)
## a GamebryoCollisionBody child holding CollisionShape3D children when
## there's real collision to attach (see mesh_resolver.gd's
## populate_collision_children() — GamebryoReference is Node3D, not
## StaticBody3D, so the physics body is a composed child here, not
## inherited). No extra fields of its own — the shape is structural
## (children), not data.
##
## This is also the class the shared default factory instantiates directly
## for every Tier 1 type that hasn't diverged from this shape yet (see
## phases/1/01-object-type-registry.md) — dedicated subclasses
## (DoorNode, ContainerNode, ...) exist only where identity is useful today,
## not for every type up front.
