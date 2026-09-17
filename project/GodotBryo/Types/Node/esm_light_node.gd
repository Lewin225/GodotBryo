@tool
@icon("res://GodotBryo/Types/Node/light.svg")
class_name EsmLightNode
extends EsmNode

## Resource-backed LIGH representation. The optional fixture comes from
## NifServer while the authored Light3D exists immediately.
func _on_reference_ready() -> void:
	if reference == null or not reference.base is LightBase:
		return
	var light_base := reference.base as LightBase
	var authored_color: Color = light_base.color
	var light_color := authored_color.linear_to_srgb() # Godot expects srgb, gamebyro is linear
	var light_range: float = max(light_base.radius, 0.1) * 2.0
	var light_name := "SpotLight3D" if light_base.is_spot_light else "OmniLight3D"
	if get_node_or_null(light_name) != null:
		return
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
	light.name = light_name
	light.light_color = light_color
	light.light_energy = -1.0 if light_base.is_negative else 1.0
	light.shadow_enabled = light_base.casts_spot_shadows or not light_base.is_spot_light
	light.visible = not light_base.is_off_by_default


	# Dispite being a forward rendering pipeline engine godot can draw a lot of lights with not much issue
	# But some cells have over 100 lights, this is near free since gamebyro is a deffered pipeline
	# Problem isn't performance so much as running out of space in the shadow map, so try to cull shadows a little
	light.distance_fade_enabled = true
	light.distance_fade_begin = 50
	light.distance_fade_shadow = 20
	light.distance_fade_length = 10

	add_generated_child(light)
