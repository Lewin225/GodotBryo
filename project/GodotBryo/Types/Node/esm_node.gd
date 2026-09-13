@tool
class_name EsmNode
extends Node3D

## Runtime representation of one ESM reference.
## The reference is the only ESM data entry point; its Base is reached through
## reference.base and is never duplicated on the node.

# The reference identity/placement is scene data. Its derived `base` resource
# remains non-persistent on EsmReference and is rehydrated from EsmServer.
@export_custom(PROPERTY_HINT_RESOURCE_TYPE, "EsmReference", PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY) var reference: EsmReference:
	set(value):
		reference = value
		_visual_built = false
		_reference_changed()

var _visual_built := false
var _waiting_for_esm := false

## Default activation hook for all physicalized ESM nodes.
## Type-specific nodes override this for their native default behavior.
func activate(_actor: Node = null) -> Dictionary:
	return {}

func configure(esm_reference: EsmReference) -> void:
	reference = esm_reference

## Returns the live world transform used by gameplay. Static ESM nodes use
## their own transform; physical nodes override this to query their body.
func get_runtime_global_transform() -> Transform3D:
	return global_transform if is_inside_tree() else transform

func get_runtime_global_position() -> Vector3:
	return get_runtime_global_transform().origin

## Builds the visual children for this reference. Unknown/base nodes remain a
## valid empty Node3D until their typed construction path exists.
func build_visual(_resolver: GamebryoMeshResolver) -> void:
	pass

## Shared dynamic-object assembly used by typed nodes whose NIF hierarchy and
## animation tracks must remain intact.
func build_dynamic_visual(resolver: GamebryoMeshResolver, model_path: String) -> bool:
	if resolver == null or model_path.is_empty():
		return false
	var nif := resolver.load_nif(model_path)
	if nif == null or nif.get_submesh_count() == 0:
		return false
	var geometry := resolver.build_geometry_entries(resolver.resolve_raw_geometry(nif, model_path))
	var built := resolver.populate_dynamic_children(self, nif, model_path, geometry)
	resolver.populate_animation_player(self, nif, built)
	resolver.populate_direct_controller_player(self, nif, built)
	_visual_built = true
	return true

func _reference_changed() -> void:
	call_deferred("_rehydrate_and_build")

func _rehydrate_and_build() -> void:
	if reference == null or _visual_built:
		return
	var root := get_tree().root if is_inside_tree() else null
	var server = root.get_node_or_null("EsmServer") if root != null else null
	if reference.base == null and server != null:
		if not server.is_ready():
			if not _waiting_for_esm:
				_waiting_for_esm = true
				server.esm_ready.connect(_on_esm_ready, CONNECT_ONE_SHOT)
			return
		var hydrated: EsmReference = null
		if not reference.instance_id.is_empty():
			hydrated = server.get_reference(reference.instance_id)
		if hydrated == null and reference.base_form_id != 0:
			hydrated = server.create_reference_for_base(reference.base_form_id)
		if hydrated != null:
			reference = hydrated
			return
	if reference.base == null:
		return
	# A packed editor preview already contains the generated hierarchy. The
	# reference may still need rehydration, but rebuilding here would append a
	# second copy of the visible mesh and animation tree on top of it.
	if get_child_count() > 0:
		_visual_built = true
		return
	var resolver := GamebryoMeshResolver.new()
	build_visual(resolver)

func _on_esm_ready() -> void:
	_waiting_for_esm = false
	_rehydrate_and_build()
