// The lit NIF shader (BSShaderPPLightingProperty, NifMaterialBuilder.PATH_LIT).
// NifMaterialBuilder generates each variant: `shader_type spatial;`, a
// render_mode line (blend, depth draw, depth test, cull), the defines below,
// then this file. Lighting, shadows, fog and GI are Godot's. The surface
// maths follows Godot 4.7.1's StandardMaterial3D (metallic 0), with the NIF's
// specular: roughness from the material's glossiness and specular from the
// normal map's alpha, on shapes with the Specular flag; roughness 1 and
// specular 0 on the rest.
//
// Defines:
//   NIF_ALPHA     writes ALPHA (blended and alpha-scissor variants)
//   NIF_SCISSOR   alpha scissor at alpha_scissor_threshold
//   NIF_ALPHA_TEST  blended and also alpha tested: discards alpha at or below
//                   alpha_scissor_threshold (NiAlphaProperty's GREATER test)
//
// Instance uniforms are per MeshInstance3D, so a shared material keeps
// batching while each instance animates or is tinted on its own:
//   nif_alpha       multiplies the alpha (NiAlphaController)
//   nif_color       multiplies the colour (NiMaterialColorController)
//   nif_emittance   replaces the material colour and the emissive colour by
//                   its rgb, by its a (the placement's XEMI); a = 0 leaves
//                   both as they are
//   nif_emissive    the emissive colour (NiMaterialProperty, animated by
//                   NiMaterialColorController SELF_ILLUM links)
//   nif_emit_mult   the emittance multiplier (NiMaterialProperty, animated by
//                   BSMaterialEmittanceMultController)
//   nif_uv_offset_u/_v, nif_uv_scale_u/_v, nif_uv_rotate  transform the base
//                   map's UV; one float each, so a track sets a whole uniform
//                   (NiTextureTransformController, slot 0 on every link)

uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D texture_albedo : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
// 1 uses the vertex colour as albedo (StandardMaterial3D's vertex_color_use_as_albedo).
uniform float use_vertex_color = 0.0;
// The normal map; normal_scale 0 when the shape has none, which leaves the
// vertex normal.
uniform sampler2D texture_normal : hint_roughness_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_scale = 0.0;
// The Specular shader flag (flags1 bit 0): 1 draws the specular highlight,
// scaled by the normal map's alpha (the specular map); 0 draws none.
uniform float specular_enabled = 0.0;
// The highlight's roughness, from NiMaterialProperty's glossiness (the Phong
// exponent) by roughness = sqrt(2 / (glossiness + 2)).
uniform float specular_roughness = 1.0;
// The glow map (slot 2); white when the shape has none, so the emissive
// colour lights the whole surface.
uniform sampler2D texture_emission : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
#if defined(NIF_SCISSOR) || defined(NIF_ALPHA_TEST)
uniform float alpha_scissor_threshold = 0.5;
#endif

// Scales the emission, which this renderer applies in linear space: the
// original multiplied emissive x multiplier in gamma space, so the same
// values come out dimmer here. Tuned by eye in game, not derived.
const float EMISSION_SCALE = 2.0;
// The highlight's strength where the specular map is white: 75% of
// StandardMaterial3D's default 0.5. Tuned by eye in game, not derived.
const float SPECULAR_SCALE = 0.375;

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
	METALLIC = 0.0;
	// The normal map's alpha is the specular map: it scales the highlight's
	// strength, white for full shine; a DXT1 normal map has no alpha and
	// reads 1. Full strength is SPECULAR_SCALE.
	vec4 normal_tex = texture(texture_normal, UV);
	ROUGHNESS = mix(1.0, specular_roughness, specular_enabled);
	SPECULAR = SPECULAR_SCALE * normal_tex.a * specular_enabled;
	NORMAL_MAP = normal_tex.rgb;
	NORMAL_MAP_DEPTH = normal_scale;
	// Emission is a lighting term, as in OpenMW's bs/default shader: the
	// emissive colour times the multiplier (the original lit shaders'
	// EmittanceColor and MatEmit inputs), times the glow map (white when the
	// shape has none), lighting the surface's colour. # ASSUMPTION: the
	// original combines them the same way; not checked against it.
	vec3 glow = texture(texture_emission, UV).rgb;
	vec3 emissive = mix(nif_emissive.rgb, nif_emittance.rgb, nif_emittance.a);
	EMISSION = ALBEDO * emissive * nif_emit_mult * glow * EMISSION_SCALE;
#ifdef NIF_ALPHA
	// NiAlphaController keys run from -0.5 to 2 in the shipped corpus; the
	// alpha is clamped to 0..1. # ASSUMPTION: Gamebryo clamps it the same way.
	ALPHA = clamp(albedo_color.a * nif_color.a * albedo_tex.a * nif_alpha, 0.0, 1.0);
#endif
#ifdef NIF_SCISSOR
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor_threshold;
#endif
#ifdef NIF_ALPHA_TEST
	if (ALPHA <= alpha_scissor_threshold) {
		discard;
	}
#endif
}
