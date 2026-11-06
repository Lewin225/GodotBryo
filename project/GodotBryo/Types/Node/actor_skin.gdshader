shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// An actor's skin (EsmActorNode._apply_skin): the race's texture for the part
// with the NPC's FaceGen offset applied in 8-bit (sRGB) space. The offset is
// the face map's texel on the head, decoded as 2 x (value - 0.5), or
// `skin_offset` on the body and hands; both are in 8-bit levels / 255.

// How the offset combines with the texture.
// 0: added. 1: multiplied as 1 + offset (the face map as a 2x modulate).
uniform int blend_mode : hint_range(0, 1) = 0;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_texture : hint_roughness_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_normal_texture = false;
// The stock material's vertex_color_use_as_albedo.
uniform bool use_vertex_color = false;
// A facemod or a face map built from the head EGT, read as raw values.
uniform sampler2D face_map : filter_linear_mipmap, repeat_enable;
uniform bool use_face_map = false;
uniform vec3 skin_offset = vec3(0.0);
uniform float roughness : hint_range(0.0, 1.0) = 1.0;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float specular : hint_range(0.0, 1.0) = 0.5;

vec3 linear_to_srgb(vec3 color) {
	vec3 low = color * 12.92;
	vec3 high = 1.055 * pow(color, vec3(1.0 / 2.4)) - 0.055;
	return mix(high, low, lessThan(color, vec3(0.0031308)));
}

vec3 srgb_to_linear(vec3 color) {
	vec3 low = color / 12.92;
	vec3 high = pow((color + 0.055) / 1.055, vec3(2.4));
	return mix(high, low, lessThan(color, vec3(0.04045)));
}

void fragment() {
	vec3 base = texture(albedo_texture, UV).rgb;
	if (use_vertex_color) {
		base *= COLOR.rgb;
	}
	vec3 offset = skin_offset;
	if (use_face_map) {
		offset = (texture(face_map, UV).rgb - 0.5) * 2.0;
	}
	vec3 srgb = linear_to_srgb(base);
	if (blend_mode == 0) {
		srgb += offset;
	} else {
		srgb *= 1.0 + offset;
	}
	ALBEDO = srgb_to_linear(clamp(srgb, vec3(0.0), vec3(1.0)));
	if (use_normal_texture) {
		NORMAL_MAP = texture(normal_texture, UV).rgb;
	}
	ROUGHNESS = roughness;
	METALLIC = metallic;
	SPECULAR = specular;
}
