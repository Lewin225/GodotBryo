class_name GamebryoRigidBody
extends RigidBody3D

## Physics composition counterpart to GamebryoCollisionBody. The logical
## REFR remains its GamebryoVisual parent; raycasts resolve through this.
var owner_ref: Node3D = null

## Source identity for authored NIF physics. These are diagnostic/runtime
## fields, not a second ESM reference or a replacement for owner_ref.
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var nif_node_name: String = ""
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var nif_physics_body_index: int = -1
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var nif_body_data: Dictionary = {}
