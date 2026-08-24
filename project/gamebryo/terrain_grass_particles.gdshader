// GPU placement for one real GRAS variant.  This is deliberately separate
// from Terrain3D's example shader: the project stores real BTXT+ATXT data in
// N=7 ID/weight maps, not Terrain3D's legacy two-texture control map.
shader_type particles;
render_mode disable_velocity, disable_force;

uniform int target_slot = -1;
uniform int grass_choice_index = 0;
uniform int grass_choice_count = 1;
uniform float grass_density = 0.0;
uniform float min_slope_degrees = 0.0;
uniform float max_slope_degrees = 90.0;
uniform bool fit_to_slope = false;
uniform float position_range = 0.0;
uniform float instance_spacing = 0.5;
uniform int instance_rows = 1;
uniform vec3 emitter_origin = vec3(0.0);
// Stable per-LTEX phase.  All GNAM choices for the same texture share this
// lattice (so they remain mutually exclusive); different painted textures do
// not generate candidates at exactly the same world coordinates.
uniform vec2 placement_phase = vec2(0.0);
uniform float ring_inner_distance = 0.0;
uniform float fade_start_distance = 0.0;
uniform float fade_end_distance = 0.0;
uniform float vertex_spacing = 1.0;
uniform float region_size = 256.0;
uniform int region_map[1024];
uniform highp sampler2DArray height_maps : repeat_disable;
uniform highp sampler2DArray tex_id_a_maps : repeat_disable;
uniform highp sampler2DArray tex_id_b_maps : repeat_disable;
uniform highp sampler2DArray weight_a_maps : repeat_disable;
uniform highp sampler2DArray weight_b_maps : repeat_disable;

float rand(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

ivec3 map_index(vec2 world_xz) {
	ivec2 absolute_vertex = ivec2(floor(world_xz / vertex_spacing));
	ivec2 region = ivec2(floor(vec2(absolute_vertex) / region_size)) + ivec2(16);
	if (uint(region.x | region.y) >= 32u) return ivec3(0, 0, -1);
	int layer = region_map[region.y * 32 + region.x] - 1;
	ivec2 local = ivec2(mod(vec2(absolute_vertex), region_size));
	return ivec3(local, layer);
}

float final_weight_for_target(ivec3 index) {
	if (index.z < 0) return 0.0;
	ivec4 ids_a = ivec4(round(texelFetch(tex_id_a_maps, index, 0) * 255.0));
	ivec3 ids_b = ivec3(round(texelFetch(tex_id_b_maps, index, 0).rgb * 255.0));
	vec4 wa = texelFetch(weight_a_maps, index, 0);
	vec2 wb = texelFetch(weight_b_maps, index, 0).rg;
	int ids[7] = int[7](ids_a.x, ids_a.y, ids_a.z, ids_a.w, ids_b.x, ids_b.y, ids_b.z);
	float alpha[7] = float[7](1.0, wa.x, wa.y, wa.z, wa.w, wb.x, wb.y);
	// Match Terrain3D main.glsl's sequential alpha-over exactly, but retain
	// each layer's final contribution rather than its shaded colour.
	float result = 0.0;
	for (int i = 0; i < 7; i++) {
		float contribution = i == 0 ? 1.0 : clamp(alpha[i], 0.0, 1.0);
		for (int later = i + 1; later < 7; later++) contribution *= 1.0 - clamp(alpha[later], 0.0, 1.0);
		if (ids[i] == target_slot) result += contribution;
	}
	return clamp(result, 0.0, 1.0);
}

float height_at_vertex(vec2 vertex_coord, out bool valid) {
	ivec3 index = map_index(vertex_coord * vertex_spacing);
	valid = index.z >= 0;
	return valid ? texelFetch(height_maps, index, 0).r : 0.0;
}

// Terrain3D's height array is stored at real terrain vertices.  Particle
// positions are continuous, so a nearest-texel lookup produces visibly
// stepped roots on slopes.  Bilinear interpolation matches the terrain
// surface between those vertices and works across region boundaries because
// every corner is resolved through map_index().
float terrain_height(vec2 world_xz, out bool valid) {
	vec2 vertex_coord = world_xz / vertex_spacing;
	vec2 lo = floor(vertex_coord);
	vec2 frac_coord = fract(vertex_coord);
	bool a_valid, b_valid, c_valid, d_valid;
	float a = height_at_vertex(lo, a_valid);
	float b = height_at_vertex(lo + vec2(1.0, 0.0), b_valid);
	float c = height_at_vertex(lo + vec2(0.0, 1.0), c_valid);
	float d = height_at_vertex(lo + vec2(1.0, 1.0), d_valid);
	valid = a_valid && b_valid && c_valid && d_valid;
	return mix(mix(a, b, frac_coord.x), mix(c, d, frac_coord.x), frac_coord.y);
}

vec3 terrain_normal(vec2 world_xz, out bool valid) {
	bool left_valid, right_valid, down_valid, up_valid;
	float h_left = terrain_height(world_xz - vec2(vertex_spacing, 0.0), left_valid);
	float h_right = terrain_height(world_xz + vec2(vertex_spacing, 0.0), right_valid);
	float h_down = terrain_height(world_xz - vec2(0.0, vertex_spacing), down_valid);
	float h_up = terrain_height(world_xz + vec2(0.0, vertex_spacing), up_valid);
	valid = left_valid && right_valid && down_valid && up_valid;
	return normalize(vec3(h_left - h_right, 2.0 * vertex_spacing, h_down - h_up));
}

void start() {
	// GPUParticles supplies an emission transform, but this simulation owns
	// every component of world placement.  Start from a known basis so stale
	// emitter-space state can never affect an instance.
	TRANSFORM = mat4(1.0);
	ivec2 local_index = ivec2(int(INDEX % uint(instance_rows)), int(INDEX / uint(instance_rows))) - ivec2(instance_rows / 2);
	// Anchor candidates to a global integer lattice, not the moving particle
	// window.  On a camera-grid restart, an overlapping world point therefore
	// gets exactly the same coordinate, selection, rotation and jitter.
	ivec2 origin_index = ivec2(round(emitter_origin.xz / instance_spacing));
	vec2 candidate_xz = (vec2(origin_index + local_index) + placement_phase) * instance_spacing;
	vec2 pos_xz = candidate_xz;
	pos_xz += (vec2(rand(pos_xz), rand(pos_xz + 19.0)) - 0.5) * position_range;
	ivec3 index = map_index(pos_xz);
	// Choose between an LTEX's GNAM variants from the shared candidate point,
	// rather than the per-variant position-jittered point.
	int chosen_grass = int(floor(rand(candidate_xz + 71.0) * float(max(grass_choice_count, 1))));
	float radial_distance = length(pos_xz - emitter_origin.xz);
	// Distant grass thins stochastically instead of ending at a visible
	// square boundary. The stable random acceptance test below avoids flicker.
	float distance_fade = 1.0 - smoothstep(fade_start_distance, fade_end_distance, radial_distance);
	// Clamp the boosted local density before the distance factor.  Applying
	// the fade to an already-saturated value would leave the outer ring fully
	// populated until the final few metres, causing obvious forward pop-in.
	float coverage = min(final_weight_for_target(index) * grass_density, 1.0) * distance_fade;
	bool height_valid;
	float height = terrain_height(pos_xz, height_valid);
	bool normal_valid;
	vec3 normal = terrain_normal(pos_xz, normal_valid);
	float slope_degrees = degrees(acos(clamp(normal.y, -1.0, 1.0)));
	// Fail closed.  An unavailable/invalid texture-array layer may produce a
	// NaN fetch result; `random > NaN` is false in GLSL, which would otherwise
	// accept every unrelated emitter.  A genuine painted contribution is
	// necessarily strictly positive, so this form rejects both zero and NaN.
	bool has_coverage = coverage > 0.0;
	if (index.z < 0 || radial_distance < ring_inner_distance || !height_valid || !normal_valid || chosen_grass != grass_choice_index || !has_coverage || slope_degrees < min_slope_degrees || slope_degrees > max_slope_degrees || rand(pos_xz + 43.0) > coverage) {
		TRANSFORM[3].xyz = vec3(100000.0);
	} else {
		// A stable yaw based on the shared candidate lattice breaks the visible
		// repeated-facing pattern without changing as the camera grid restarts.
		// Rotate around the fitted terrain normal when requested, otherwise Y.
		vec3 up = fit_to_slope ? normal : vec3(0.0, 1.0, 0.0);
		vec3 base_right = normalize(cross(up, vec3(0.0, 0.0, 1.0)));
		vec3 base_forward = normalize(cross(base_right, up));
		float yaw = rand(candidate_xz + 137.0) * 6.28318530718;
		TRANSFORM[0].xyz = base_right * cos(yaw) + base_forward * sin(yaw);
		TRANSFORM[1].xyz = up;
		TRANSFORM[2].xyz = base_forward * cos(yaw) - base_right * sin(yaw);
		TRANSFORM[3].xyz = vec3(pos_xz.x, height, pos_xz.y);
	}
}
