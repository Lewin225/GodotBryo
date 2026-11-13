// specular_viewer: shows a texture's RGB, or its alpha as grey.
shader_type canvas_item;

// 1 shows the alpha channel as grey; 0 shows RGB with alpha ignored.
uniform float show_alpha = 0.0;

void fragment() {
	vec4 texel = texture(TEXTURE, UV);
	COLOR = show_alpha > 0.5 ? vec4(vec3(texel.a), 1.0) : vec4(texel.rgb, 1.0);
}
