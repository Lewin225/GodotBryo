// The lit NIF shader (BSShaderPPLightingProperty, NifMaterialBuilder.PATH_LIT).
// NifMaterialBuilder generates each variant: `shader_type spatial;`, a
// render_mode line (blend, depth draw, depth test, cull), the defines below,
// then this file. Lighting, shadows, fog and GI are Godot's. The surface
// maths follows Godot 4.7.1's StandardMaterial3D with its defaults (metallic
// 0, roughness 1, specular 0.5), so a shape looks as it did as a
// StandardMaterial3D.
//
// Defines:
//   NIF_ALPHA     writes ALPHA (blended and alpha-scissor variants)
//   NIF_SCISSOR   alpha scissor at alpha_scissor_threshold
//
// Instance uniforms are per MeshInstance3D, so a shared material keeps
// batching while each instance animates or is tinted on its own:
//   nif_alpha       multiplies the alpha (NiAlphaController)
//   nif_color       multiplies the colour (NiMaterialColorController)
//   nif_emittance   replaces the material colour by its rgb and adds it as
//                   emission, by its a (the placement's XEMI); a = 0 leaves
//                   both as they are
//   nif_uv_offset, nif_uv_scale  transform the UV (NiTextureTransformController)

uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D texture_albedo : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
// 1 uses the vertex colour as albedo (StandardMaterial3D's vertex_color_use_as_albedo).
uniform float use_vertex_color = 0.0;
// The normal map; normal_scale 0 when the shape has none, which leaves the
// vertex normal.
uniform sampler2D texture_normal : hint_roughness_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_scale = 0.0;
// The glow map (slot 2); black when the shape has none.
uniform sampler2D texture_emission : source_color, hint_default_black, filter_linear_mipmap, repeat_enable;
#ifdef NIF_SCISSOR
uniform float alpha_scissor_threshold = 0.5;
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
	METALLIC = 0.0;
	ROUGHNESS = 1.0;
	SPECULAR = 0.5;
	NORMAL_MAP = texture(texture_normal, uv).rgb;
	NORMAL_MAP_DEPTH = normal_scale;
	vec3 emission_tex = texture(texture_emission, uv).rgb;
	EMISSION = nif_emittance.rgb * nif_emittance.a + emission_tex;
#ifdef NIF_ALPHA
	ALPHA = albedo_color.a * nif_color.a * albedo_tex.a * nif_alpha;
#endif
#ifdef NIF_SCISSOR
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor_threshold;
#endif
}
