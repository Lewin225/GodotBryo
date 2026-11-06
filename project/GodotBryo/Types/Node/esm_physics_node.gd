@tool
class_name EsmPhysicsNode
extends EsmNode

## A placed reference whose NIF may carry a moving body (a NifRigidBody): items
## (EsmItemNode) and movable statics (EsmMovableStaticNode). Without one it is
## an ordinary EsmNode.
##
## The body starts frozen and is released asleep at its placement once no node
## under the same streaming root (its cell or tile) still waits on a NIF: it
## stays where it was placed until something wakes it (a body moving into it, a
## neighbour picked up), as a hat hung on a hat stand whose collision is only
## its pole stays on the stand in the game.
##
## When the body falls asleep the node moves to where the body came to rest.
## The reference takes that placement only when it is more than
## WRITE_BACK_DISTANCE or WRITE_BACK_ANGLE from the placement it holds, and a
## PhysicsRef line is printed; small settling never marks a reference dirty.

## How far a body must come to rest from the reference's placement, in metres,
## before the reference takes the new placement.
const WRITE_BACK_DISTANCE := 0.1
## How far it must turn, in radians, before the reference takes the new
## placement.
const WRITE_BACK_ANGLE := deg_to_rad(25.0)
## How much the body's bounds grow, in metres, to find the bodies resting
## against it.
const NEIGHBOUR_MARGIN := 0.05
## The longest a body waits for its surroundings' NIFs before it is released
## anyway, in seconds.
const SURROUNDINGS_TIMEOUT := 10.0
## How often a waiting body checks its surroundings, in seconds.
const SURROUNDINGS_CHECK_INTERVAL := 0.25

## The NIF's moving body, the first NifRigidBody in its tree; null when the
## model has none or it is not built yet.
var body: NifRigidBody
## The node the body moves, and its transform relative to this node when the
## tree was delivered.
var _body_owner: Node3D
var _body_owner_rest := Transform3D.IDENTITY


func _on_nif_visual_ready(tree: Node3D) -> void:
	super._on_nif_visual_ready(tree)
	for found in tree.find_children("*", "RigidBody3D", true, false):
		if found is NifRigidBody:
			body = found as NifRigidBody
			break
	if body == null:
		return
	_body_owner = body.get_parent() as Node3D
	_body_owner_rest = global_transform.affine_inverse() * _body_owner.global_transform
	body.sleeping_state_changed.connect(_on_body_sleeping_state_changed)
	body.freeze = true
	_release_when_surroundings_built()


## Unfreezes the body asleep once nothing under this node's parent waits on a NIF, or
## after SURROUNDINGS_TIMEOUT. Stays frozen while the reference is disabled or
## its stream state has turned collision off.
func _release_when_surroundings_built() -> void:
	var started := Time.get_ticks_msec()
	while is_inside_tree() and body != null and _surroundings_pending() > 0:
		if Time.get_ticks_msec() - started > SURROUNDINGS_TIMEOUT * 1000.0:
			break
		await get_tree().create_timer(SURROUNDINGS_CHECK_INTERVAL, false, true).timeout
	if not is_inside_tree() or body == null or _collision_is_off():
		return
	body.freeze = false
	body.sleeping = true


## How many EsmNodes under this node's parent have a NIF request outstanding.
func _surroundings_pending() -> int:
	var parent := get_parent()
	if parent == null:
		return 0
	var pending := 0
	var stack: Array[Node] = [parent]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		var esm_node := node as EsmNode
		if esm_node != null and esm_node.is_visual_request_pending():
			pending += 1
		stack.append_array(node.get_children())
	return pending


## Whether the body's collision is off, for a disabled reference or paused
## streaming.
func _collision_is_off() -> bool:
	for child in body.get_children():
		var shape_node := child as CollisionShape3D
		if shape_node != null and shape_node.disabled:
			return true
	return false


func _on_body_sleeping_state_changed() -> void:
	if body.sleeping:
		_settle()


## Moves this node to where the body came to rest, keeping the meshes where
## they are, and writes the placement to the reference when it moved far
## enough.
func _settle() -> void:
	if reference == null or _body_owner == null or get_parent() == null:
		return
	var owner_scale := _body_owner.global_basis.get_scale()
	var owner_at_rest := Transform3D(body.global_basis.orthonormalized().scaled_local(owner_scale), body.global_position)
	var node_global := owner_at_rest * _body_owner_rest.affine_inverse()
	var local := (get_parent() as Node3D).global_transform.affine_inverse() * node_global if get_parent() is Node3D else node_global
	var placement := EsmReferencePhysicaliser.authored_placement(local)
	transform = EsmReferencePhysicaliser.placement_transform(placement["position"], placement["rotation"], reference.scale)
	_body_owner.global_transform = owner_at_rest
	if _moved_far(placement["position"], placement["rotation"]):
		var moved: float = (placement["position"] as Vector3).distance_to(reference.position)
		var turned := rad_to_deg(_turn(placement["rotation"]))
		reference.rotation = placement["rotation"]
		reference.set_location(reference.current_space_form_id, placement["position"])
		print("PhysicsRef: %s (%s) came to rest %.2f m and %.0f degrees from its placement; reference dirty" % [reference.instance_id, reference.base.editor_id, moved, turned])


## Whether a resting placement is far enough from the reference's to write.
func _moved_far(new_position: Vector3, new_rotation: Vector3) -> bool:
	if new_position.distance_to(reference.position) > WRITE_BACK_DISTANCE:
		return true
	return _turn(new_rotation) > WRITE_BACK_ANGLE


## The angle, in radians, between the reference's rotation and `new_rotation`.
func _turn(new_rotation: Vector3) -> float:
	var held := EsmReferencePhysicaliser.authored_rotation_basis(reference.rotation)
	var resting := EsmReferencePhysicaliser.authored_rotation_basis(new_rotation)
	return Quaternion(held.orthonormalized()).angle_to(Quaternion(resting.orthonormalized()))


## Wakes every other body overlapping this node's body's bounds, grown by
## NEIGHBOUR_MARGIN: the bodies resting on or against it.
func wake_neighbours() -> void:
	if body == null or not body.is_inside_tree():
		return
	var bounds := _collision_bounds()
	if bounds.size == Vector3.ZERO:
		return
	var box := BoxShape3D.new()
	box.size = bounds.size + Vector3.ONE * NEIGHBOUR_MARGIN * 2.0
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = box
	query.transform = Transform3D(Basis.IDENTITY, bounds.get_center())
	query.exclude = [body.get_rid()]
	var hits := body.get_world_3d().direct_space_state.intersect_shape(query, 64)
	for hit: Dictionary in hits:
		var other := hit["collider"] as RigidBody3D
		if other != null and not other.freeze:
			other.sleeping = false


## The world-space bounds of the body's collision shapes.
func _collision_bounds() -> AABB:
	var bounds := AABB()
	var first := true
	for child in body.get_children():
		var shape_node := child as CollisionShape3D
		if shape_node == null or shape_node.shape == null:
			continue
		var shape_bounds := shape_node.global_transform * shape_node.shape.get_debug_mesh().get_aabb()
		bounds = shape_bounds if first else bounds.merge(shape_bounds)
		first = false
	return bounds
