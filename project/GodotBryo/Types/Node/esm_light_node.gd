@tool
@icon("res://GodotBryo/Types/Node/light.svg")
class_name EsmLightNode
extends EsmNode

## Resource-backed LIGH representation. The optional fixture model and the
## authored Light3D are built under the same reference root.
func build_visual(resolver: GamebryoMeshResolver) -> void:
	if reference == null or not reference.base is LightBase:
		return
	var light_base := reference.base as LightBase
	if not light_base.model_path.is_empty():
		var nif := resolver.load_nif(light_base.model_path)
		if nif != null and nif.get_submesh_count() > 0:
			var geometry := resolver.build_geometry_entries(resolver.resolve_raw_geometry(nif, light_base.model_path))
			resolver.populate_mesh_children(self, nif, light_base.model_path, geometry)
			resolver.populate_collision_children(self, nif, light_base.model_path, geometry)

	var authored_color: Color = light_base.color
	var light_color := authored_color.linear_to_srgb()
	var light_range: float = max(light_base.radius, 0.1) * 2.0
	var light: Light3D
	if light_base.is_spot_light:
		var spot := SpotLight3D.new()
		spot.spot_angle = clamp(light_base.fov_degrees * 0.5, 1.0, 89.0)
		spot.spot_range = light_range
		spot.spot_attenuation = max(light_base.falloff_exponent, 0.01)
		light = spot
	else:
		var omni := OmniLight3D.new()
		omni.omni_range = light_range
		omni.omni_attenuation = max(light_base.falloff_exponent, 0.01)
		light = omni
	light.name = "SpotLight3D" if light_base.is_spot_light else "OmniLight3D"
	light.light_color = light_color
	light.light_energy = -1.0 if light_base.is_negative else 1.0
	light.shadow_enabled = light_base.casts_spot_shadows or not light_base.is_spot_light
	light.visible = not light_base.is_off_by_default
	add_child(light)
	_visual_built = true
