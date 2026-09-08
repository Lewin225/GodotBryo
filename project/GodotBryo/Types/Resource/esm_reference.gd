@tool
class_name EsmReference
extends Resource

@export var base_form_id: int = 0
@export var instance_id: String = ""
@export var position: Vector3 = Vector3.ZERO
@export var rotation: Vector3 = Vector3.ZERO
@export var scale: float = 1.0
@export var current_cell_form_id: int = 0
var base: EsmBase
