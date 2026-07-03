shader_type spatial;

// Flowing OSM water (rivers/streams/canals). The mesh is draped onto the terrain by
// WaterBuilder so it follows the downhill contour; per-vertex COLOR carries the local
// downhill flow direction (rg, decoded to -1..1) and slope-scaled speed (b). Ripples
// and foam streaks scroll downstream along that direction, faster on steeper reaches.
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_lambert, specular_schlick_ggx;

uniform vec4 deep_color : source_color = vec4(0.03, 0.12, 0.16, 1.0);
uniform vec4 shallow_color : source_color = vec4(0.14, 0.34, 0.40, 1.0);
uniform vec4 foam_color : source_color = vec4(0.86, 0.93, 0.97, 1.0);
uniform float water_alpha : hint_range(0.4, 1.0) = 0.88;
uniform float flow_speed = 1.1;                        // world units/sec base scroll
uniform float wave_scale = 0.09;
uniform float ripple_strength : hint_range(0.0, 0.6) = 0.18;
uniform float foam_amount : hint_range(0.0, 1.0) = 0.40;
uniform float base_roughness : hint_range(0.0, 0.3) = 0.06;
uniform float gloss_roughness : hint_range(0.0, 0.15) = 0.02;
uniform float base_specular : hint_range(0.0, 1.0) = 0.42;
uniform float gloss_specular : hint_range(0.0, 1.0) = 0.90;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(41.3, 289.1))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

varying vec3 v_flow;   // xz = downhill direction, y = speed 0..1

void vertex() {
	vec2 dir = COLOR.rg * 2.0 - 1.0;
	v_flow = vec3(dir.x, COLOR.b, dir.y);
}

void fragment() {
	vec2 dir = normalize(v_flow.xz + vec2(1e-5, 0.0));
	float spd = clamp(v_flow.y, 0.05, 1.0);
	float t = TIME;
	vec2 uv = VERTEX.xz;

	// Coordinate scrolled downstream; ripples travel along the flow, speed ∝ slope.
	vec2 scroll = dir * (t * flow_speed * (0.4 + spd));
	vec2 across = vec2(-dir.y, dir.x);
	float along = dot(uv - scroll, dir);
	float aw = dot(uv - scroll * 1.3, across);
	float w1 = sin(along * wave_scale * 6.2831 + t * 2.0);
	float w2 = sin(aw * wave_scale * 3.1 + t * 1.3);
	vec3 n = normalize(vec3(
		dir.x * w1 * ripple_strength + across.x * w2 * ripple_strength * 0.4,
		1.0,
		dir.y * w1 * ripple_strength + across.y * w2 * ripple_strength * 0.4));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);

	float ndv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fres = pow(1.0 - ndv, 3.5);

	// Foam streaks: noise stretched along the flow, drifting downstream; heavier where
	// the reach is steep (faster) so rapids read differently from slow water.
	vec2 fcoord = vec2(along * 0.12, dot(uv, across) * 0.5);
	float streak = vnoise(fcoord - vec2(t * (0.6 + spd), 0.0));
	float foam = smoothstep(0.58, 0.96, streak) * foam_amount * spd;

	vec3 base = mix(deep_color.rgb, shallow_color.rgb, fres * 0.5);
	ALBEDO = mix(base, foam_color.rgb, foam);
	ROUGHNESS = mix(base_roughness, gloss_roughness, fres) + foam * 0.3;
	SPECULAR = mix(base_specular, gloss_specular, fres);
	METALLIC = 0.0;
	ALPHA = water_alpha;
}
