class_name GamebryoCollisionBody
extends StaticBody3D

## Composition body for a GamebryoVisual's collision (enginedocs/
## nv_class_hierarchy.md: GamebryoReference moved from StaticBody3D to
## Node3D so a Dynamic type's identity isn't tied to a specific physics
## body -- collision becomes a CHILD a node adds when it needs one, not
## something every node inherits whether it needs it or not).
##
## A physics raycast against a GamebryoVisual's collision hits THIS node as
## `collider`, not the GamebryoVisual/DoorNode/etc itself -- callers (e.g.
## game.gd's interact raycast) must resolve `collider.owner_ref` to reach
## the real GamebryoReference to call activate() on, instead of assuming
## the collider IS the reference.

var owner_ref: Node3D = null
