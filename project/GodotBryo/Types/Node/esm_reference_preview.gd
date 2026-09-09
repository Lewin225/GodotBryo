@tool
class_name EsmReferencePreview
extends Node3D

## Editor-only container behavior for an unsaved physicalised-reference
## preview. The authored reference node remains a direct child; its position
## is reset to the container origin while its authored rotation and scale are
## preserved.
func _ready() -> void:
	call_deferred("center_direct_children")

func center_direct_children() -> void:
	for child in get_children():
		if child is Node3D:
			(child as Node3D).position = Vector3.ZERO
