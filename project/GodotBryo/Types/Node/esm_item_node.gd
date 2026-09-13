@tool
@icon("res://GodotBryo/Types/Node/item.svg")
class_name EsmItemNode
extends EsmNode

var _physics_bodies: Array = []

## First-pass physical representation for loose item objects. Pickup,
## inventory, and drag interactions remain in the legacy path for now; this
## node only establishes the resource-backed visual and authored physics path.
func build_visual(resolver: GamebryoMeshResolver) -> void:
	if not _is_supported_item_reference(reference) or reference.base == null:
		return
	var model_path := String(reference.base.get("model_path"))
	if model_path.is_empty():
		return
	var nif := resolver.load_nif(model_path)
	if nif == null or nif.get_submesh_count() == 0:
		return
	var geometry := resolver.build_geometry_entries(resolver.resolve_raw_geometry(nif, model_path))
	_physics_bodies = resolver.populate_authored_rigid_bodies(self, nif, model_path, geometry)
	_visual_built = true

static func _is_supported_item_reference(value: EsmReference) -> bool:
	return value is MiscReference or value is AlchemyReference or value is AmmoReference \
			or value is KeyReference or value is WeaponReference \
			or value is ArmorReference or value is BookReference \
			or value is CaravanCardReference or value is CaravanMoneyReference

func _ready() -> void:
	call_deferred("_sync_physics_transform")

## The wrapper remains at its authored REFR transform. Query callers that need
## the item's current physical location use this instead of global_transform.
func get_runtime_global_transform() -> Transform3D:
	if not _physics_bodies.is_empty():
		var body: GamebryoRigidBody = _physics_bodies[0]
		if is_instance_valid(body) and body.is_inside_tree():
			return body.global_transform
	return global_transform

func _sync_physics_transform() -> void:
	if _physics_bodies.is_empty():
		return
	var body: GamebryoRigidBody = _physics_bodies[0]
	if not is_instance_valid(body):
		return
	if not is_inside_tree():
		return
	body.global_transform = global_transform
