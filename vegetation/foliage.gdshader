// Foliage card shader for MultiMeshInstance3D-based vegetation scatter.
shader_type spatial;
render_mode cull_disabled;

#include "res://vegetation/wind_vertex.gdshaderinc"

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D drape_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform bool use_drape = false;
uniform float drape_extent_m = 30000.0;
uniform float drape_match_strength : hint_range(0.0, 1.0) = 0.0;
uniform vec3  albedo_tint : source_color = vec3(1.0);
uniform vec3  highlight_tint : source_color = vec3(1.0);
uniform float alpha_dither_min : hint_range(0.0, 1.0) = 0.20;
uniform float alpha_dither_max : hint_range(0.0, 1.0) = 0.50;
uniform float dither_strength : hint_range(0.0, 1.0) = 1.0;
uniform float trunk_uv_cutoff : hint_range(0.0, 1.0) = 0.0;
uniform float near_crisp_m : hint_range(0.0, 120.0) = 40.0;
uniform float far_dither_m : hint_range(40.0, 300.0) = 120.0;
uniform float roughness_value  : hint_range(0.0, 1.0) = 0.95;
uniform vec3  ao_tint : source_color = vec3(0.65, 0.7, 0.55);
uniform float ao_strength : hint_range(0.0, 1.0) = 0.35;
uniform vec3  haze_color    : source_color           = vec3(0.07, 0.13, 0.04);
uniform float haze_start    : hint_range(0.0, 2000.0) = 200.0;
uniform float haze_end      : hint_range(0.0, 2000.0) = 700.0;
uniform float haze_strength : hint_range(0.0, 1.0)   = 0.65;
uniform float lean_amount : hint_range(0.0, 1.0) = 0.30;
uniform float subsurface_strength : hint_range(0.0, 1.0) = 0.0;
uniform float hue_jitter : hint_range(0.0, 0.15) = 0.0;
uniform float seasonal_strength : hint_range(0.0, 1.0) = 0.0;
uniform vec3 seasonal_tint : source_color = vec3(1.0, 0.92, 0.75);
uniform float night_factor : hint_range(0.0, 1.0) = 0.0;
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);

varying float v_view_dist;
varying vec3 v_world_pos;

void vertex() {
	float top_mask = 1.0 - UV.y;
	vec3 inst_pos = MODEL_MATRIX[3].xyz;
	float vert_phase = dot(VERTEX, vec3(17.3, 31.1, 11.7));
	VERTEX = apply_vegetation_wind(VERTEX, inst_pos, top_mask, vert_phase);

	vec3 to_cam_xz = CAMERA_POSITION_WORLD - inst_pos;
	to_cam_xz.y = 0.0;
	float cam_dist_xz = length(to_cam_xz);
	float lean_blend = smoothstep(30.0, 100.0, cam_dist_xz);
	vec3 lean_dir = cam_dist_xz > 0.5 ? to_cam_xz / cam_dist_xz : vec3(0.0, 0.0, 1.0);

	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_pos += lean_dir * (top_mask * top_mask * lean_amount * lean_blend);

	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos, 1.0);
	v_view_dist = length((VIEW_MATRIX * vec4(world_pos, 1.0)).xyz);
	v_world_pos = world_pos;
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);

	float dist_t = clamp((v_view_dist - haze_start) / max(haze_end - haze_start, 1.0), 0.0, 1.0);
	float dmin = mix(alpha_dither_min, alpha_dither_min * 0.4, dist_t);
	float dmax = mix(alpha_dither_max, alpha_dither_max * 0.5, dist_t);

	vec2  px      = floor(FRAGCOORD.xy);
	float dither  = fract(sin(dot(px, vec2(12.9898, 78.233))) * 43758.5453);
	float threshold = mix(dmin, dmax, dither);

	bool use_scissor = (trunk_uv_cutoff > 0.0 && UV.y > trunk_uv_cutoff)
		|| (near_crisp_m > 0.0 && v_view_dist < near_crisp_m);
	float crisp_blend = 1.0 - smoothstep(near_crisp_m, far_dither_m, v_view_dist);
	if (crisp_blend > 0.5) {
		use_scissor = true;
	}

	float eff_thresh = mix(threshold, 0.35, 1.0 - dither_strength);
	if (use_scissor) {
		if (tex.a < 0.35) {
			discard;
		}
	} else if (tex.a < eff_thresh) {
		discard;
	}

	float face_factor = 1.0;
	if (!FRONT_FACING) {
		NORMAL      = -NORMAL;
		face_factor = 0.30;
	}

	vec3 albedo = tex.rgb * albedo_tint * face_factor;
	if (hue_jitter > 0.0) {
		vec2 cell = floor(v_world_pos.xz / 3.0);
		float hj = fract(sin(dot(cell, vec2(41.0, 289.0))) * 43758.5453) * 2.0 - 1.0;
		albedo *= 1.0 + hj * hue_jitter;
	}
	if (seasonal_strength > 0.0) {
		albedo = mix(albedo, albedo * seasonal_tint, seasonal_strength);
	}

	if (use_drape && drape_match_strength > 0.0 && drape_extent_m > 0.0) {
		vec2 duv = (v_world_pos.xz + drape_extent_m * 0.5) / drape_extent_m;
		if (duv.x >= 0.0 && duv.x <= 1.0 && duv.y >= 0.0 && duv.y <= 1.0) {
			vec3 drape = texture(drape_tex, duv).rgb;
			albedo = mix(albedo, albedo * drape / max(drape.g, 0.05), drape_match_strength);
		}
	}

	float bottom_t = UV.y;
	albedo = mix(albedo, albedo * ao_tint, bottom_t * ao_strength);

	vec3 lit_dir = normalize(sun_direction);
	float sun_up = max(0.0, dot(lit_dir, NORMAL)) * (1.0 - night_factor);
	albedo += highlight_tint * sun_up * subsurface_strength * (1.0 - UV.y);

	float haze_amount = dist_t * haze_strength * (1.0 - night_factor);
	ALBEDO    = albedo * (1.0 - haze_amount);
	EMISSION  = haze_color * haze_amount;

	ROUGHNESS = roughness_value;
	METALLIC  = 0.0;
}
