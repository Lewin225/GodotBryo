@tool
@icon("res://GodotBryo/Types/Node/static.svg")
class_name EsmStaticNode
extends EsmNode

## Resource-backed STAT representation. NifServer supplies its individual
## mesh/collision tree; batching remains a future world-streaming policy.


## A STAT never moves, though about 260 STAT models carry a moving rigid body:
## each NifRigidBody NifServer built is frozen in place.
func _on_nif_visual_ready(tree: Node3D) -> void:
	super._on_nif_visual_ready(tree)
	for body in tree.find_children("*", "RigidBody3D", true, false):
		var rigid := body as NifRigidBody
		if rigid == null:
			continue
		rigid.set_meta("esm_always_frozen", true)
		rigid.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
		rigid.freeze = true
