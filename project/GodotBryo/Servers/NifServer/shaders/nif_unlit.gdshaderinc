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
//   nif_emissive, nif_emit_mult  declared as on the lit shader, so tracks
//                   and the tree builder address every shape alike; not
//                   used. # ASSUMPTION: the original's NOLIGHT shaders do
//                   not draw the emissive colour (3,941 unlit shapes carry a
//                   black one and are visible)
//   nif_uv_offset_u/_v, nif_uv_scale_u/_v, nif_uv_rotate  transform the base
//                   map's UV; one float each, so a track sets a whole uniform
//                   (NiTextureTransformController, slot 0 on every link)

uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D texture_albedo : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
// 1 uses the vertex colour as albedo (StandardMaterial3D's vertex_color_use_as_albedo).
uniform float use_vertex_color = 0.0;
// BSShaderNoLightingProperty's falloff, on shapes with flags1 bit 6: the
// alpha fades with the angle between the surface and the view, from
// falloff_start_opacity where its cosine is falloff_start_angle (or more,
// facing the viewer) to falloff_stop_opacity where it is falloff_stop_angle
// (or less, edge-on). Both sides fade alike. falloff_enabled 0 leaves the
// alpha as it is. # ASSUMPTION: linear in the cosine.
uniform float falloff_enabled = 0.0;
uniform float falloff_start_angle = 1.0;
uniform float falloff_stop_angle = 0.0;
uniform float falloff_start_opacity = 1.0;
uniform float falloff_stop_opacity = 1.0;
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
instance uniform vec4 nif_emissive : source_color = vec4(0.0, 0.0, 0.0, 1.0);
instance uniform float nif_emit_mult = 1.0;
instance uniform float nif_uv_offset_u = 0.0;
instance uniform float nif_uv_offset_v = 0.0;
instance uniform float nif_uv_scale_u = 1.0;
instance uniform float nif_uv_scale_v = 1.0;
instance uniform float nif_uv_rotate = 0.0;

void fragment() {
	// The base map's UV transform: scaled, translated, then rotated about the
	// texture centre, in radians. # ASSUMPTION: Gamebryo's order, centre and
	// unit; not checked against the original.
	vec2 base_uv = UV * vec2(nif_uv_scale_u, nif_uv_scale_v)
			+ vec2(nif_uv_offset_u, nif_uv_offset_v) - vec2(0.5);
	float rotate_sin = sin(nif_uv_rotate);
	float rotate_cos = cos(nif_uv_rotate);
	base_uv = vec2(base_uv.x * rotate_cos - base_uv.y * rotate_sin,
			base_uv.x * rotate_sin + base_uv.y * rotate_cos) + vec2(0.5);
	vec4 albedo_tex = texture(texture_albedo, base_uv);
	// COLOR is read only when the shape uses vertex colour, as
	// StandardMaterial3D does.
	if (use_vertex_color > 0.5) {
		albedo_tex *= COLOR;
	}
	vec3 material_color = mix(albedo_color.rgb, nif_emittance.rgb, nif_emittance.a);
	ALBEDO = material_color * nif_color.rgb * albedo_tex.rgb;
#ifdef NIF_ALPHA
	// NiAlphaController keys run from -0.5 to 2 in the shipped corpus; the
	// alpha is clamped to 0..1. # ASSUMPTION: Gamebryo clamps it the same way.
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float falloff_span = max(falloff_start_angle - falloff_stop_angle, 0.0001);
	float falloff_t = clamp((falloff_start_angle - facing) / falloff_span, 0.0, 1.0);
	float falloff = mix(1.0, mix(falloff_start_opacity, falloff_stop_opacity, falloff_t), falloff_enabled);
	ALPHA = clamp(albedo_color.a * nif_color.a * albedo_tex.a * nif_alpha * falloff, 0.0, 1.0);
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
