// Shared vegetation wind displacement — include from foliage/bark/canopy shaders.
uniform float wind_strength : hint_range(0.0, 0.3) = 0.03;
uniform float wind_speed_ms : hint_range(0.0, 40.0) = 2.0;
uniform float gust_intensity : hint_range(0.0, 1.0) = 0.0;
uniform vec2 wind_direction = vec2(0.0, 1.0);
uniform float sway_frequency : hint_range(0.2, 2.0) = 0.7;
// 0 = conifer, 1 = deciduous, 2 = shrub
uniform float wind_profile = 0.0;

vec3 apply_vegetation_wind(vec3 vertex, vec3 inst_pos, float top_mask, float vert_phase) {
	vec2 downwind = wind_direction;
	if (dot(downwind, downwind) < 1e-4) {
		downwind = vec2(0.0, 1.0);
	} else {
		downwind = normalize(downwind);
	}
	vec2 crosswind = vec2(-downwind.y, downwind.x);

	float trunk_scale = mix(0.30, mix(1.0, 0.10, step(1.5, wind_profile)), step(0.5, wind_profile));
	float branch_scale = mix(1.20, mix(0.80, 0.60, step(1.5, wind_profile)), step(0.5, wind_profile));
	float leaf_scale = mix(0.20, mix(1.00, 1.20, step(1.5, wind_profile)), step(0.5, wind_profile));

	float speed_t = clamp(wind_speed_ms / 12.0, 0.05, 1.6);
	float amp = wind_strength * (0.35 + speed_t * 0.85);
	float world_phase = inst_pos.x * 0.17 + inst_pos.z * 0.13;
	float t = TIME * sway_frequency;

	float trunk_sway = sin(t * 0.55 + world_phase) * amp * top_mask * top_mask * trunk_scale;
	float branch = sin(t * 1.85 + world_phase * 1.7 + vert_phase) * amp * 0.65 * top_mask * branch_scale;
	float flutter = sin(t * 9.5 + vert_phase * 3.1) * amp * 0.22 * top_mask * leaf_scale;

	float gust_n = sin(t * 2.3 + inst_pos.x * 0.05) * sin(t * 3.7 + inst_pos.z * 0.04);
	float gust = gust_n * gust_intensity * amp * 0.35 * top_mask;

	float disp = (trunk_sway + branch + flutter + gust) * speed_t;
	float cross = sin(t * 2.1 + world_phase * 2.3 + vert_phase) * amp * 0.18 * top_mask * branch_scale * speed_t;

	vertex.x += downwind.x * disp + crosswind.x * cross;
	vertex.z += downwind.y * disp + crosswind.y * cross;

	if (wind_profile > 0.5 && wind_profile < 1.5) {
		vertex.y += sin(t * 11.0 + vert_phase) * amp * 0.08 * top_mask * leaf_scale * speed_t;
	}

	return vertex;
}
