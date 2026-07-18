shader_type spatial;

// Aerial drape for additive earthworks (berms / pads). Samples the detail/hyper
// ortho by world XZ so the texture follows sloped embankments instead of a
// baked flat UV rectangle. half_extent_m must match the bound texture patch.
render_mode cull_disabled, diffuse_lambert, specular_schlick_ggx;

uniform sampler2D ortho_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform float half_extent_m = 500.0;
uniform vec3 dirt_tint : source_color = vec3(0.92, 0.90, 0.86);
uniform float roughness_value : hint_range(0.0, 1.0) = 0.88;

varying vec3 v_world_pos;
varying vec3 v_world_normal;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float he = max(half_extent_m, 1.0);
	vec2 uv = vec2(
		clamp((v_world_pos.x + he) / (2.0 * he), 0.0, 1.0),
		clamp((v_world_pos.z + he) / (2.0 * he), 0.0, 1.0)
	);
	vec3 ortho = texture(ortho_tex, uv).rgb;
	// Slight dirt mix + slope darkening so embankments read as earth, not a
	// floating photo sticker.
	float slope = 1.0 - clamp(dot(normalize(v_world_normal), vec3(0.0, 1.0, 0.0)), 0.0, 1.0);
	vec3 col = mix(ortho, ortho * dirt_tint, 0.18 + slope * 0.22);
	col *= mix(1.0, 0.82, slope);
	ALBEDO = col;
	ROUGHNESS = roughness_value;
}
