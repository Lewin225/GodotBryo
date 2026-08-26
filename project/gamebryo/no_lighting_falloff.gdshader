shader_type spatial;
// Fallout's light-beam/cookie effects are visibly two-sided in play even
// where the source NIF does not carry the generic double-sided mesh flag.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

// BSShaderNoLightingProperty with SLSF1_USE_FALLOFF.  Fallout's source
// values describe alpha at two view-angle cosines; retain the NIF's texture
// and vertex alpha, then multiply the authored angular fade per fragment.
uniform sampler2D albedo_texture : source_color;
uniform vec4 emittance_tint : source_color = vec4(1.0);
uniform float falloff_start_angle = 1.0;
uniform float falloff_stop_angle = 0.0;
uniform float falloff_start_opacity = 1.0;
uniform float falloff_stop_opacity = 1.0;
// Godot has no equivalent to Gamebryo's close-camera effect clipping
// behaviour. Fade in world space before the camera reaches the translucent
// volume, so near-plane intersection never exposes its internal faces.
uniform float camera_fade_distance = 1.5;

varying vec4 gamebryo_vertex_color;
varying vec3 gamebryo_world_position;

void vertex() {
	gamebryo_vertex_color = COLOR;
	gamebryo_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec4 source = texture(albedo_texture, UV) * gamebryo_vertex_color;
	float denominator = falloff_start_angle - falloff_stop_angle;
	float t = clamp((dot(normalize(NORMAL), normalize(VIEW)) - falloff_stop_angle) / max(abs(denominator), 0.00001), 0.0, 1.0);
	if (denominator < 0.0) {
		t = 1.0 - t;
	}
	float angular_opacity = mix(falloff_stop_opacity, falloff_start_opacity, t);
	float camera_opacity = smoothstep(0.0, max(camera_fade_distance, 0.001),
		distance(gamebryo_world_position, CAMERA_POSITION_WORLD));
	ALBEDO = source.rgb * emittance_tint.rgb;
	ALPHA = source.a * emittance_tint.a * angular_opacity * camera_opacity;
}
