class_name GamebryoCharacterBody
extends CharacterBody3D

## Physics composition counterpart to GamebryoCollisionBody/GamebryoRigidBody,
## for the Actor branch (issue #52 chunk 3; enginedocs/nv_class_hierarchy.md's
## "Actors — a sibling of GamebryoVisual, same root, same composition trick").
## The logical REFR remains its GamebryoActor parent; raycasts resolve
## through this, same convention as the other two composed bodies.
var owner_ref: Node3D = null
