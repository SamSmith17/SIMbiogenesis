// Dedicated turf shader — opaque blades, ground tint, distance fade to patch.
shader_type spatial;
render_mode cull_disabled;

#include "res://vegetation/wind_vertex.gdshaderinc"

uniform vec3 root_color : source_color = vec3(0.10, 0.32, 0.08);
uniform vec3 tip_color : source_color = vec3(0.14, 0.42, 0.12);
uniform vec3 highlight_color : source_color = vec3(0.28, 0.58, 0.18);
uniform vec3 albedo_tint : source_color = vec3(1.0);
uniform sampler2D drape_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform bool use_drape = false;
uniform float drape_extent_m = 30000.0;
uniform float drape_match_strength : hint_range(0.0, 1.0) = 0.35;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.92;
uniform float subsurface_strength : hint_range(0.0, 1.0) = 0.45;
uniform float near_full_m : hint_range(0.0, 80.0) = 35.0;
uniform float mid_fade_m : hint_range(20.0, 200.0) = 90.0;
uniform float far_patch_m : hint_range(80.0, 400.0) = 280.0;
uniform float patch_strength : hint_range(0.0, 1.0) = 0.85;
uniform float night_factor : hint_range(0.0, 1.0) = 0.0;
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform float hue_jitter : hint_range(0.0, 0.15) = 0.04;

varying float v_view_dist;
varying float v_height_t;
varying vec3 v_world_pos;

void vertex() {
	float top_mask = 1.0 - UV.y;
	v_height_t = top_mask;
	vec3 inst_pos = MODEL_MATRIX[3].xyz;
	float vert_phase = dot(VERTEX, vec3(17.3, 31.1, 11.7));
	VERTEX = apply_vegetation_wind(VERTEX, inst_pos, top_mask, vert_phase);
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos, 1.0);
	v_view_dist = length((VIEW_MATRIX * vec4(world_pos, 1.0)).xyz);
	v_world_pos = world_pos;
}

void fragment() {
	float dist_fade = 1.0 - smoothstep(mid_fade_m, far_patch_m, v_view_dist);
	float patch_blend = smoothstep(mid_fade_m, far_patch_m, v_view_dist) * patch_strength;
	float blade_fade = smoothstep(far_patch_m * 0.92, far_patch_m, v_view_dist);

	vec3 base = mix(root_color, tip_color, v_height_t);
	base = mix(base, highlight_color, smoothstep(0.55, 1.0, v_height_t) * 0.35);
	base *= albedo_tint;

	if (hue_jitter > 0.0) {
		vec2 cell = floor(v_world_pos.xz / 2.5);
		float hj = fract(sin(dot(cell, vec2(41.0, 289.0))) * 43758.5453) * 2.0 - 1.0;
		base *= 1.0 + hj * hue_jitter;
	}

	if (use_drape && drape_match_strength > 0.0 && drape_extent_m > 0.0) {
		vec2 duv = (v_world_pos.xz + drape_extent_m * 0.5) / drape_extent_m;
		if (duv.x >= 0.0 && duv.x <= 1.0 && duv.y >= 0.0 && duv.y <= 1.0) {
			vec3 drape = texture(drape_tex, duv).rgb;
			base = mix(base, base * drape / max(drape.g, 0.05), drape_match_strength * 0.55);
		}
	}

	vec3 lit_dir = normalize(sun_direction);
	float sun_up = max(0.0, dot(lit_dir, NORMAL)) * (1.0 - night_factor);
	base += highlight_color * sun_up * subsurface_strength * v_height_t;

	// Far distance: flatten to a ground-tinted patch (no alpha pop).
	vec3 patch_col = mix(root_color, tip_color, 0.35) * albedo_tint;
	if (use_drape && drape_extent_m > 0.0) {
		vec2 duv2 = (v_world_pos.xz + drape_extent_m * 0.5) / drape_extent_m;
		if (duv2.x >= 0.0 && duv2.x <= 1.0 && duv2.y >= 0.0 && duv2.y <= 1.0) {
			vec3 drape2 = texture(drape_tex, duv2).rgb;
			patch_col = mix(patch_col, patch_col * drape2 / max(drape2.g, 0.05), 0.65);
		}
	}
	vec3 albedo = mix(base * dist_fade + patch_col * patch_blend, patch_col, blade_fade);

	ALBEDO = albedo;
	ROUGHNESS = roughness_value;
	METALLIC = 0.0;
}
