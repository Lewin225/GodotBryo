// The refraction NIF shader (BSShaderPPLightingProperty with the Refraction
// flag, NifMaterialBuilder.PATH_REFRACTION): explosion shock spheres, muzzle
// warps, shield fields. As the original's refraction pixel shaders (SLS2075,
// SLS2076, SM3032-3034, which take only NormalMap and PSRefractionPower), it
// draws no colour: it writes the screen offset into a distortion buffer, and
// a full-screen pass (the original's ISREFRACT; here RefractionEffect, a
// compositor effect after the transparent pass) offsets the finished frame by
// it, particles included.
//
// Only RefractionCapture's camera draws it: every other camera discards it.
// That camera's visible layers are exactly RefractionCapture.LAYER_MASK, and
// NifTreeBuilder puts refraction shapes on that layer.
//
// Output, in the distortion buffer (RGBA16F, linear):
//   r, g  0.5 + the screen UV offset: the normal map's xy (from 0..1 to
//         -1..1) times nif_refraction_strength
//   b     the shape's depth (FRAGCOORD.z), for RefractionEffect to drop a
//         shape behind opaque geometry; above 0 wherever a shape covers the
//         pixel (Godot's reversed Z puts the far plane at 0, the cleared
//         background's value)
//
// Instance uniforms, set from the shape's BSShaderPPLightingProperty by
// NifTreeBuilder and animated by its controllers:
//   nif_refraction_strength  the offset's scale, in screen UV
//                            (BSRefractionStrengthController)
//   nif_refraction_period    the fire refraction's scroll period
//                            (BSRefractionFirePeriodController)

shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled, ambient_light_disabled;

// RefractionCapture.LAYER_MASK: visual layer 20 alone.
const uint DISTORTION_CAMERA_LAYERS = 1u << 19u;

// The distortion normal map; flat (0.5, 0.5) when the shape has none.
uniform sampler2D texture_normal : hint_normal, filter_linear_mipmap, repeat_enable;
// The Fire Refraction shader flag (flags1 bit 16): 1 scrolls the normal map.
uniform float fire_refraction = 0.0;

instance uniform float nif_refraction_strength = 0.0;
instance uniform float nif_refraction_period = 0.0;

void fragment() {
	if (CAMERA_VISIBLE_LAYERS != DISTORTION_CAMERA_LAYERS) {
		discard;
	}
	vec2 distortion_uv = UV;
	// # ASSUMPTION: the fire period is the seconds the normal map takes to
	// scroll once along V, its sign the direction (census: -22 to 200, an int).
	if (fire_refraction > 0.5 && nif_refraction_period != 0.0) {
		distortion_uv.y += TIME / nif_refraction_period;
	}
	vec2 offset = (texture(texture_normal, distortion_uv).xy * 2.0 - 1.0) * nif_refraction_strength;
	ALBEDO = vec3(0.5 + offset.x, 0.5 + offset.y, FRAGCOORD.z);
}
