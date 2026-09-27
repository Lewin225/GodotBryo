@tool
class_name EsmPrimitiveVolume
extends Area3D

## The XPRM primitive of a placed reference (trigger box, acoustic space,
## sound emitter, room portal) as an Area3D, a child of the reference's
## EsmNode. At runtime it reports actors entering and leaving to ScriptServer:
## OnTriggerEnter and OnTriggerLeave once, OnTrigger every physics frame while
## an actor is inside, each with that actor's reference as the action ref.
## Other bodies (world geometry, items) are ignored.

## The reference whose primitive this is.
var reference: EsmReference
## Actor references currently inside, as {EsmReference: true}.
var _occupants: Dictionary = {}

## Builds the shape from `ref`'s primitive. The bounds are in Gamebryo axes
## (Z up); the parent EsmNode's frame is Godot-facing (Y up), so Gamebryo
## X/Y/Z extents become Godot X/Z/Y. Bounds are taken as half-extents.
func configure(ref: EsmReference) -> void:
	reference = ref
	name = "PrimitiveVolume"
	monitorable = false
	collision_layer = 0
	collision_mask = 1
	var shape := CollisionShape3D.new()
	var bounds: Vector3 = ref.primitive_bounds
	if ref.primitive_type == EsmReference.PrimitiveType.SPHERE:
		var sphere := SphereShape3D.new()
		sphere.radius = maxf(bounds.x, 0.01)
		shape.shape = sphere
	else:
		var box := BoxShape3D.new()
		box.size = Vector3(bounds.x, bounds.z, bounds.y).abs().max(Vector3.ONE * 0.005) * 2.0
		shape.shape = box
	add_child(shape)
	if not Engine.is_editor_hint():
		body_entered.connect(_on_body_entered)
		body_exited.connect(_on_body_exited)

func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint() or _occupants.is_empty() or not _has_script():
		return
	for actor: EsmReference in _occupants.keys():
		ScriptServer.dispatch_event(reference, "OnTrigger", actor)

func _on_body_entered(body: Node3D) -> void:
	var actor := actor_reference_for(body)
	if actor == null or _occupants.has(actor):
		return
	_occupants[actor] = true
	if _has_script():
		ScriptServer.dispatch_event(reference, "OnTriggerEnter", actor)

func _on_body_exited(body: Node3D) -> void:
	var actor := actor_reference_for(body)
	if actor == null or not _occupants.has(actor):
		return
	_occupants.erase(actor)
	if _has_script():
		ScriptServer.dispatch_event(reference, "OnTriggerLeave", actor)

func _has_script() -> bool:
	return reference != null and reference.base != null and reference.base.script_form_id != 0

## The actor reference a physics body stands for, or null: a body that
## possesses an actor (the player's) stands for that actor; any other body
## for its EsmNode's reference when that is an actor or creature.
static func actor_reference_for(body: Node) -> EsmReference:
	if body == null:
		return null
	if "possessed" in body:
		return body.get("possessed") as EsmReference
	var node := body
	while node != null:
		if node is EsmNode:
			var ref: EsmReference = (node as EsmNode).reference
			return ref if (ref is ActorReference or ref is CreatureReference) else null
		node = node.get_parent()
	return null
