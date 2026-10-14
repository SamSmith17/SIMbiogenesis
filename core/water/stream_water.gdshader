shader_type spatial;

// Flowing water for the stream network (StreamMeshBuilder). The strip sits
// level in its carved channel, so the look is driven by HOW MUCH WATER is in
// front of the bed at each pixel: the scene depth behind the surface gives the
// water column, which sets absorption (clear and bed-coloured in the shallows,
// dark in the pool), a soft shoreline (no hard ribbon edge) and shore foam.
//
// Ripples ride a two-phase FLOW MAP: two copies of the same noise advect along
// the per-vertex downstream direction half a cycle apart, crossfaded with a
// triangle wave, so the pattern moves with the current forever without the
// stretching a single scrolling texture gets.
//
// Vertex data (see StreamMeshBuilder): COLOR.rg downstream dir, COLOR.b speed
// 0..1, COLOR.a white water 0..1, UV world xz, UV2 (lateral −1..1, arc m).
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_lambert, specular_schlick_ggx;

#include "res://core/soi/shaders/soi_clip.gdshaderinc"

uniform sampler2D depth_tex : hint_depth_texture, filter_linear_mipmap;

uniform vec4 deep_color : source_color = vec4(0.020, 0.085, 0.100, 1.0);
uniform vec4 shallow_color : source_color = vec4(0.16, 0.30, 0.27, 1.0);
uniform vec4 foam_color : source_color = vec4(0.88, 0.94, 0.97, 1.0);
// Water column (m) at which the bed is no longer visible.
uniform float clarity_m : hint_range(0.1, 6.0) = 1.4;
// Shoreline fade + foam band (m of water column).
uniform float shore_m : hint_range(0.005, 1.0) = 0.035;
uniform float shore_foam : hint_range(0.0, 1.0) = 0.55;
uniform float flow_speed_ms = 1.2;        // advection speed at COLOR.b = 1
uniform float flow_speed_scale : hint_range(0.3, 2.5) = 1.0;
uniform float flow_churn : hint_range(0.4, 2.0) = 1.0;
uniform float ripple_scale = 0.55;        // ripple frequency (1/m)
uniform float ripple_strength : hint_range(0.0, 0.8) = 0.32;
uniform float foam_amount : hint_range(0.0, 1.0) = 0.6;
uniform float water_alpha : hint_range(0.4, 1.0) = 0.92;
uniform float base_roughness : hint_range(0.0, 0.3) = 0.05;
uniform float base_specular : hint_range(0.0, 1.0) = 0.5;

varying vec3 v_world_pos;
varying vec4 v_flow;
varying float v_lat;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(41.3, 289.1))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

// Height field of the ripple pattern (two octaves).
float ripples(vec2 p) {
	return vnoise(p) * 0.65 + vnoise(p * 2.13 + 7.1) * 0.35;
}

vec2 ripple_grad(vec2 p) {
	float e = 0.08;
	float h = ripples(p);
	return vec2(ripples(p + vec2(e, 0.0)) - h, ripples(p + vec2(0.0, e)) - h) / e;
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_flow = COLOR;
	v_lat = UV2.x;
}

void fragment() {
	soi_clip_fragment(v_world_pos);
	vec2 dir = v_flow.rg * 2.0 - 1.0;
	dir = length(dir) > 1e-4 ? normalize(dir) : vec2(1.0, 0.0);
	float spd = clamp(v_flow.b, 0.04, 1.0);
	float white = v_flow.a;

	// --- water column behind this pixel -----------------------------------
	float d = texture(depth_tex, SCREEN_UV).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, d * 2.0 - 1.0);
#else
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, d);
#endif
	vec4 bh = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	vec3 behind = bh.xyz / bh.w;
	float column = max(VERTEX.z - behind.z, 0.0);

	// --- two-phase flow-mapped ripples ------------------------------------
	vec2 uv = v_world_pos.xz * ripple_scale;
	float t = TIME * flow_speed_ms * flow_speed_scale * (0.25 + spd) * ripple_scale;
	float ph0 = fract(t * 0.25);
	float ph1 = fract(t * 0.25 + 0.5);
	float w = abs(ph0 * 2.0 - 1.0);
	vec2 g0 = ripple_grad(uv - dir * ph0 * 4.0);
	vec2 g1 = ripple_grad(uv - dir * ph1 * 4.0 + 13.7);
	vec2 g = mix(g0, g1, w) * ripple_strength * flow_churn * (0.6 + spd);
	vec3 n_world = normalize(vec3(-g.x, 1.0, -g.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	float ndv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fres = pow(1.0 - ndv, 4.0);

	// --- colour: absorption over the column -------------------------------
	float depth01 = clamp(column / clarity_m, 0.0, 1.0);
	vec3 base = mix(shallow_color.rgb, deep_color.rgb, sqrt(depth01));

	// Foam: streaks stretched along the flow, plus the white water a steep or
	// fast reach makes, plus a lap line where the column thins at the bank.
	vec2 across = vec2(-dir.y, dir.x);
	vec2 fc = vec2(dot(v_world_pos.xz, dir) * 0.35, dot(v_world_pos.xz, across) * 1.6);
	float streak = vnoise(fc - vec2(TIME * flow_speed_ms * flow_speed_scale * (0.3 + spd) * 0.35, 0.0));
	float foam = smoothstep(0.62, 0.95, streak) * foam_amount * spd * flow_churn;
	foam += smoothstep(0.35, 0.85, streak + white * 0.6) * white;
	// Lap line: only where the column thins AND we are near the strip edge —
	// a shallow brook is thin everywhere and must not turn white all over.
	float edge = smoothstep(0.7, 1.0, abs(v_lat));
	float lap = (1.0 - smoothstep(0.0, shore_m * 2.5, column)) * edge;
	foam += lap * shore_foam * (0.5 + 0.5 * vnoise(v_world_pos.xz * 3.0 + TIME * 0.4));
	foam = clamp(foam, 0.0, 1.0);

	ALBEDO = mix(base, foam_color.rgb, foam);
	ROUGHNESS = base_roughness + foam * 0.45;
	SPECULAR = mix(base_specular, 0.95, fres) * (1.0 - foam * 0.6);
	METALLIC = 0.0;
	// Clear in the shallows (the bed shows through), opaque in the pool, and a
	// soft edge where the water meets the bank.
	// Soft edges two ways: where the bank cuts the plane (column → 0) and at
	// the strip's own edge (lateral → ±1), so neither reads as a hard ribbon.
	float shore = smoothstep(0.0, shore_m, column) * (1.0 - smoothstep(0.82, 1.0, abs(v_lat)));
	ALPHA = clamp(mix(0.55, water_alpha, depth01) + foam * 0.4, 0.0, 1.0) * shore;
}
