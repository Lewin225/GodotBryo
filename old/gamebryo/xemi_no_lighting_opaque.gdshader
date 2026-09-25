shader_type spatial;
render_mode unshaded;

// Opaque XEMI NoLighting backing planes must stay in the opaque HDR pass so
// their explicit EMISSION is gathered by Godot's glow stage.
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
	// See xemi_no_lighting.gdshader: this is authored self-lit surface colour,
	// so HDR belongs in the unlit albedo output rather than an emitter path.
	ALBEDO = color * emission_energy;
}
