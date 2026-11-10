// The unlit NIF shader (BSShaderNoLightingProperty, NifMaterialBuilder.PATH_UNLIT).
// NifMaterialBuilder generates each variant: `shader_type spatial;`, a
// render_mode line (unshaded, blend, depth draw, depth test, cull), the
// defines below, then this file. The maths follows Godot 4.7.1's
// StandardMaterial3D for the same features, so a shape looks as it did as a
// StandardMaterial3D.
//
// Defines:
//   NIF_ALPHA             writes ALPHA (blended and alpha-scissor variants)
//   NIF_SCISSOR           alpha scissor at alpha_scissor_threshold
//   NIF_ALPHA_TEST        blended and also alpha tested: discards alpha at or
//                         below alpha_scissor_threshold (NiAlphaProperty's
//                         GREATER test)
//   NIF_PROXIMITY_FADE    fades by distance to the depth behind (light shafts)
//   NIF_DISTANCE_FADE     fades by distance to the camera (light shafts)
//
// Instance uniforms are per MeshInstance3D, so a shared material keeps
// batching while each instance animates or is tinted on its own:
//   nif_alpha       multiplies the alpha (NiAlphaController)
//   nif_color       multiplies the colour (NiMaterialColorController)
//   nif_emittance   replaces the material colour by its rgb, by its a (the
//                   placement's XEMI); a = 0 leaves the material colour
//   nif_uv_offset, nif_uv_scale  transform the UV (NiTextureTransformController)

uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D texture_albedo : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
// 1 uses the vertex colour as albedo (StandardMaterial3D's vertex_color_use_as_albedo).
uniform float use_vertex_color = 0.0;
#if defined(NIF_SCISSOR) || defined(NIF_ALPHA_TEST)
uniform float alpha_scissor_threshold = 0.5;
#endif
#ifdef NIF_PROXIMITY_FADE
uniform float proximity_fade_distance = 1.0;
uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap, repeat_disable;
#endif
#ifdef NIF_DISTANCE_FADE
uniform float distance_fade_min = 0.0;
uniform float distance_fade_max = 1.0;
#endif

instance uniform float nif_alpha = 1.0;
instance uniform vec4 nif_color : source_color = vec4(1.0);
instance uniform vec4 nif_emittance : source_color = vec4(1.0, 1.0, 1.0, 0.0);
instance uniform vec2 nif_uv_offset = vec2(0.0);
instance uniform vec2 nif_uv_scale = vec2(1.0);

void fragment() {
	vec2 uv = UV * nif_uv_scale + nif_uv_offset;
	vec4 albedo_tex = texture(texture_albedo, uv);
	// COLOR is read only when the shape uses vertex colour, as
	// StandardMaterial3D does.
	if (use_vertex_color > 0.5) {
		albedo_tex *= COLOR;
	}
	vec3 material_color = mix(albedo_color.rgb, nif_emittance.rgb, nif_emittance.a);
	ALBEDO = material_color * nif_color.rgb * albedo_tex.rgb;
#ifdef NIF_ALPHA
	ALPHA = albedo_color.a * nif_color.a * albedo_tex.a * nif_alpha;
#endif
#ifdef NIF_SCISSOR
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor_threshold;
#endif
#ifdef NIF_PROXIMITY_FADE
	float depth_tex = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec4 world_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_tex, 1.0);
	world_pos.xyz /= world_pos.w;
	ALPHA *= clamp(1.0 - smoothstep(world_pos.z + proximity_fade_distance, world_pos.z, VERTEX.z), 0.0, 1.0);
#endif
#ifdef NIF_DISTANCE_FADE
	ALPHA *= clamp(smoothstep(distance_fade_min, distance_fade_max, length(VERTEX)), 0.0, 1.0);
#endif
#ifdef NIF_ALPHA_TEST
	if (ALPHA <= alpha_scissor_threshold) {
		discard;
	}
#endif
}
