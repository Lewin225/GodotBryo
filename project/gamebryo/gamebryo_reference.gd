class_name GamebryoReference
extends Node3D

## Base layer of the placed-object hierarchy (phases/1/architecture.md).
## Every REFR has this much, regardless of what it places: its own FormID,
## the base record it points to, and its transform (already covered by
## Node3D — not duplicated here as separate fields).
##
## Root class is Node3D, not StaticBody3D (changed from the original
## StaticBody3D-rooted design — see enginedocs/nv_class_hierarchy.md):
## every subclass needs the transform, but not every subclass needs a
## physics body, and a future Actor branch needs a CharacterBody3D, not a
## static one, which a StaticBody3D-rooted base can't provide without
## fighting every existing subclass. A subclass that needs collision adds
## its own internal GamebryoCollisionBody CHILD instead (see
## GamebryoVisual/mesh_resolver.gd's populate_collision_children()) —
## composition, not inheritance, for the physics part specifically.

var form_id: int = 0 # this REFR's own FormID
var base_form_id: int = 0 # the base record (STAT/DOOR/CONT/...) it places
