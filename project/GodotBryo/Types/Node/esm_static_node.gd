@tool
@icon("res://GodotBryo/Types/Node/static.svg")
class_name EsmStaticNode
extends EsmNode

## Resource-backed STAT representation. This deliberately constructs an
## individual mesh/collision node; batching is a world-streaming policy and
## is not part of the Base/Reference physicalizer.
func build_visual(resolver: GamebryoMeshResolver) -> void:
	if reference == null or not reference.base is StaticBase:
		return
	var static_base := reference.base as StaticBase
	if static_base.model_path.is_empty():
		return
	var nif := resolver.load_nif(static_base.model_path)
	if nif == null or nif.get_submesh_count() == 0:
		return
	var geometry := resolver.build_geometry_entries(resolver.resolve_raw_geometry(nif, static_base.model_path))
	resolver.populate_mesh_children(self, nif, static_base.model_path, geometry)
	resolver.populate_collision_children(self, nif, static_base.model_path, geometry)
	_visual_built = true
