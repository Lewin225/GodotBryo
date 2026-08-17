class_name GamebryoVisual
extends GamebryoObject

## Layer for base records with MODL: has renderable geometry. Composition
## shape (phases/1/architecture.md): MeshInstance3D children built from the
## resolved NIF, one per submesh, plus (once phases/1/02-collision-extraction.md
## lands) CollisionShape3D children. No extra fields — the shape is
## structural (children), not data.
##
## This is also the class the shared default factory instantiates directly
## for every Tier 1 type that hasn't diverged from this shape yet (see
## phases/1/01-object-type-registry.md) — dedicated subclasses
## (DoorNode, ContainerNode, ...) exist only where identity is useful today,
## not for every type up front.
