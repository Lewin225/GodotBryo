class_name GamebryoReference
extends StaticBody3D

## Base layer of the placed-object hierarchy (phases/1/architecture.md).
## Every REFR has this much, regardless of what it places: its own FormID,
## the base record it points to, and its transform (already covered by
## Node3D/StaticBody3D — not duplicated here as separate fields).
##
## Root class is StaticBody3D (not Node3D) even for types that won't get a
## CollisionShape3D until 1.2 lands — an inert StaticBody3D with no shape is
## harmless, and this avoids every subclass needing to change its engine
## base type later just to gain collision.

var form_id: int = 0 # this REFR's own FormID
var base_form_id: int = 0 # the base record (STAT/DOOR/CONT/...) it places
