shader_type spatial;
render_mode unshaded, blend_mix, depth_prepass_alpha;

// REFR.XEMI colours an authored BSShaderNoLightingProperty backing layer.
// Unlike the additive/falloff effects shader, these are ordinary window and
// glow planes. Write to EMISSION explicitly so their HDR contribution enters
// Godot's glow buffer instead of relying on StandardMaterial's unshaded path.
uniform sampler2D albedo_texture : source_color;
uniform bool use_albedo_texture = false;
uniform vec4 emittance_tint : source_color = vec4(1.0);
uniform float emission_energy = 12.0;

varying vec4 gamebryo_vertex_color;

void vertex() {
	gamebryo_vertex_color = COLOR;
}

void fragment() {
	vec4 source = gamebryo_vertex_color;
	if (use_albedo_texture) {
		source *= texture(albedo_texture, UV);
	}
	vec3 color = source.rgb * emittance_tint.rgb;
	// BSShaderNoLightingProperty is an authored self-lit surface, not a
	// physical light emitter. Keep its HDR scale in the unlit colour path:
	// this is the same renderer path validated by the bright-magenta probe
	// and therefore participates in glow before tone mapping.
	ALBEDO = color * emission_energy;
	ALPHA = source.a * emittance_tint.a;
}
