class_name GamebryoRigidBody
extends RigidBody3D

## Physics composition counterpart to GamebryoCollisionBody. The logical
## REFR remains its GamebryoVisual parent; raycasts resolve through this.
var owner_ref: Node3D = null
