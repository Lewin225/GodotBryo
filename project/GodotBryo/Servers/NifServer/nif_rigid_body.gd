@tool
class_name NifRigidBody
extends RigidBody3D

## A NIF bhkRigidBody whose motion system moves (1 dynamic, 2 sphere inertia,
## 4 box inertia, 8 thin box). NifTreeBuilder builds it under the node that owns
## the collision; each frame it is awake, it moves that node to its own
## interpolated position and rotation, so the meshes follow the simulation
## smoothly. Physics moves a RigidBody3D without transform notifications, so
## this runs in _process. The owner keeps its own scale, which physics does not
## keep on a RigidBody3D.
##
## On entering the tree the body becomes top level, keeping its global
## transform, so moving the owning node does not move the body back. Built
## top level, it would treat its identity transform as global and start at the
## world origin.

## bhkRigidBody's motion system (hkMotionType).
@export var motion_system: int = 0
## bhkRigidBody's quality type (hkQualityType).
@export var quality_type: int = 0
## bhkRigidBody's solver deactivation: 1 off, 2 low to 5 max.
@export var solver_deactivation: int = 0
## bhkRigidBody's collision filter layer.
@export var layer: int = 0

var _owner_node: Node3D
var _owner_scale := Vector3.ONE

## Every NifRigidBody in the tree, for counts().
static var _live: Array[NifRigidBody] = []


## How many NifRigidBodys are in the tree: total, awake (simulating), asleep
## and frozen.
static func counts() -> Dictionary:
	var awake := 0
	var asleep := 0
	var frozen := 0
	for body in _live:
		if body.freeze:
			frozen += 1
		elif body.sleeping:
			asleep += 1
		else:
			awake += 1
	return {"total": _live.size(), "awake": awake, "asleep": asleep, "frozen": frozen}


func _enter_tree() -> void:
	if Engine.is_editor_hint():
		return
	_live.append(self)
	_owner_node = get_parent() as Node3D
	if _owner_node != null:
		_owner_scale = _owner_node.global_basis.get_scale()
	top_level = true


func _exit_tree() -> void:
	_live.erase(self)


func _process(_delta: float) -> void:
	if _owner_node == null or sleeping:
		return
	_move_owner()


## Puts the owning node where the body is, with the owner's own scale.
func _move_owner() -> void:
	var body := get_global_transform_interpolated()
	var basis := body.basis.orthonormalized().scaled_local(_owner_scale)
	_owner_node.global_transform = Transform3D(basis, body.origin)
