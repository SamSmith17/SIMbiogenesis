shader_type spatial;
render_mode cull_disabled;

// Fallen log (VegDeadwood): a unit capped cylinder along +X scaled per
// instance. INSTANCE_CUSTOM = (length m, radius m, seed 0..1, unused).
// Furrowed bark round the sides, moss wherever the surface faces up (the
// west-coast nurse-log look: a green pelt along the top, bare bark beneath),
// and a pale weathered cut face with growth rings on the ends.
// Colours are LINEAR reflectance (bark ~6-10 %, moss ~10-15 % green).

#include "res://vegetation/veg_lighting.gdshaderinc"

uniform vec3 bark_dark = vec3(0.040, 0.026, 0.016);
uniform vec3 bark_light = vec3(0.085, 0.060, 0.038);
uniform vec3 moss_color = vec3(0.075, 0.140, 0.022);
uniform vec3 moss_dry = vec3(0.110, 0.130, 0.040);
uniform vec3 cut_color = vec3(0.150, 0.118, 0.080);
uniform float moss_amount : hint_range(0.0, 1.0) = 0.85;

varying vec3 v_world;
varying vec3 v_wnormal;
varying float v_len;
varying float v_rad;
varying float v_seed;

float hash2(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash2(i), hash2(i + vec2(1.0, 0.0)), u.x),
		mix(hash2(i + vec2(0.0, 1.0)), hash2(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	return vnoise(p) * 0.55 + vnoise(p * 2.13 + 7.1) * 0.3 + vnoise(p * 4.7 + 3.3) * 0.15;
}

void vertex() {
	v_len = INSTANCE_CUSTOM.r;
	v_rad = INSTANCE_CUSTOM.g;
	v_seed = INSTANCE_CUSTOM.b;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wnormal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 wn = normalize(v_wnormal);
	float along = UV.x * max(v_len, 0.1);
	float round_m = UV.y * 6.2832 * max(v_rad, 0.05);
	vec3 col;
	if (UV2.x > 0.5) {
		// Cut face: rings by radius, a darker rotted heart, grey weathering.
		float r = UV2.y;
		float rings = 0.5 + 0.5 * sin(r * max(v_rad, 0.05) * 140.0 + v_seed * 20.0);
		col = mix(cut_color * 0.7, cut_color, rings);
		col = mix(col * 0.55, col, smoothstep(0.08, 0.35, r));
		col = mix(col, bark_dark, smoothstep(0.86, 0.97, r));
	} else {
		// Bark: deep vertical-ish furrows running along the trunk.
		float n = fbm(vec2(along * 0.9, round_m * 4.0) + v_seed * 31.0);
		float furrow = smoothstep(0.35, 0.75, 0.5 + 0.5 * sin(round_m * 9.0 + n * 5.0));
		col = mix(bark_dark, bark_light, furrow * (0.6 + 0.4 * n));
	}
	// Moss: up-facing, patchy, thicker toward the middle of the log.
	float blot = fbm(v_world.xz * 0.9 + v_seed * 13.0);
	float up = wn.y + (blot - 0.5) * 0.9;
	float mid = 1.0 - smoothstep(0.3, 0.5, abs(UV.x - 0.5));
	float moss = smoothstep(0.05, 0.55, up) * moss_amount * mix(0.65, 1.0, mid);
	vec3 mcol = mix(moss_dry, moss_color, fbm(v_world.xz * 3.1 + 5.0));
	col = mix(col, mcol, clamp(moss, 0.0, 1.0));
	ALBEDO = col;
	ROUGHNESS = mix(0.85, 1.0, moss);
	SPECULAR = 0.2;
	EMISSION = col * veg_fill_amount();
}
