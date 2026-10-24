shader_type spatial;

// Flat OSM water — level mesh + local ReflectionProbe cubemaps (placed per lake in
// WaterBuilder). Fresnel ramps specular/roughness so grazing angles pick up sky and
// shoreline trees; micro-normals break up the mirror without folding the surface.
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_schlick_ggx;

#include "res://core/soi/shaders/soi_clip.gdshaderinc"

uniform vec4 deep_color : source_color = vec4(0.02, 0.10, 0.17, 1.0);
uniform vec4 shallow_color : source_color = vec4(0.12, 0.32, 0.40, 1.0);
uniform float water_alpha : hint_range(0.4, 1.0) = 0.90;
uniform float flow_level_m : hint_range(0.0, 1.5) = 0.0;
uniform float flow_churn : hint_range(0.4, 2.0) = 1.0;
uniform float wave_speed = 0.45;
uniform float wave_scale = 0.05;
uniform float ripple_strength : hint_range(0.0, 0.5) = 0.10;
uniform float base_roughness : hint_range(0.0, 0.25) = 0.04;
uniform float gloss_roughness : hint_range(0.0, 0.15) = 0.015;
uniform float base_specular : hint_range(0.0, 1.0) = 0.45;
uniform float gloss_specular : hint_range(0.0, 1.0) = 0.92;

vec3 wave_normal(vec2 p, float t) {
	vec2 a = p * wave_scale + vec2(0.031, 0.017) * t;
	vec2 b = p * wave_scale * 1.73 + vec2(-0.024, 0.029) * t;
	float dx = (cos(a.x * 6.2831) + 0.7 * cos(b.x * 6.2831)) * ripple_strength;
	float dz = (cos(a.y * 6.2831) + 0.7 * cos(b.y * 6.2831)) * ripple_strength;
	return normalize(vec3(dx, 1.0, dz));
}

// Optional reach mask (ShorelineHistory's lake-level plane, LakeSpill): a
// texture of SPILL levels in world Y over spill_rect (x0, z0, 1/w, 1/d);
// water is drawn only where the lake can reach at spill_level. Off by
// default, so every other water body is unchanged.
uniform bool use_spill = false;
uniform sampler2D spill_tex : filter_linear, repeat_disable;
uniform vec4 spill_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform float spill_level = 0.0;

varying vec3 v_world_pos;

void vertex() {
	VERTEX.y += flow_level_m;
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	soi_clip_fragment(v_world_pos);
	if (use_spill) {
		vec2 suv = (v_world_pos.xz - spill_rect.xy) * spill_rect.zw;
		if (suv.x >= 0.0 && suv.y >= 0.0 && suv.x <= 1.0 && suv.y <= 1.0
				&& texture(spill_tex, suv).r > spill_level) {
			discard;
		}
	}
	float t = TIME * wave_speed * flow_churn;
	vec3 n_world = wave_normal(v_world_pos.xz, t);  // world xz (VERTEX is view space here)
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	float ndv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fres = pow(1.0 - ndv, 3.5);
	// Suppress grazing specular spikes (probe / sky seams) at horizon views.
	float horizon_fade = smoothstep(0.0, 0.12, ndv);

	ALBEDO = mix(deep_color.rgb, shallow_color.rgb, fres * 0.42);
	ROUGHNESS = mix(base_roughness, gloss_roughness, fres);
	SPECULAR = mix(base_specular, gloss_specular, fres) * horizon_fade;
	METALLIC = 0.0;
	ALPHA = clamp(water_alpha, 0.0, 1.0);
}
