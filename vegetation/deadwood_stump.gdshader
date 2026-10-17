shader_type spatial;
render_mode cull_disabled;

// Weathered old-growth stump (VegDeadwood) for imported stump models that
// arrive with flat paint instead of a bark texture (SketchUp "paint"
// materials read as a pale plastic stump). World-space so it needs no UVs:
// grey-brown weathered wood streaked vertically, a green moss pelt on the
// up-facing cut and root flare and a mossy collar at the foot.
// The face normal comes from screen derivatives, not the model's NORMAL:
// SketchUp exports are often double-sided or wound inside out, and the moss
// must find "up" either way. Linear colours.

#include "res://vegetation/veg_lighting.gdshaderinc"

uniform vec3 wood_dark = vec3(0.050, 0.038, 0.026);
uniform vec3 wood_grey = vec3(0.120, 0.105, 0.085);
uniform vec3 moss_color = vec3(0.070, 0.135, 0.020);
uniform vec3 moss_dry = vec3(0.105, 0.125, 0.038);

varying vec3 v_world;
varying float v_local_y;

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

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_local_y = VERTEX.y;
}

void fragment() {
	vec3 wn = normalize(cross(dFdx(v_world), dFdy(v_world)));
	float up = abs(wn.y);
	// Vertical streaks: stretch the noise along y.
	float streak = vnoise(vec2((v_world.x + v_world.z) * 6.0, v_world.y * 0.7))
		* 0.6 + vnoise(vec2((v_world.x - v_world.z) * 13.0, v_world.y * 1.4)) * 0.4;
	vec3 col = mix(wood_dark, wood_grey, smoothstep(0.25, 0.8, streak));
	float blot = vnoise(v_world.xz * 1.6) * 0.6 + vnoise(v_world.xz * 4.3 + 9.0) * 0.4;
	float top = smoothstep(0.45, 0.85, up + (blot - 0.5) * 0.6);
	float foot = 1.0 - smoothstep(0.15, 0.55, v_local_y + (blot - 0.5) * 0.35);
	float moss = clamp(max(top * 0.9, foot * 0.75), 0.0, 1.0);
	vec3 mcol = mix(moss_dry, moss_color, vnoise(v_world.xz * 3.7 + 2.0));
	col = mix(col, mcol, moss);
	ALBEDO = col;
	ROUGHNESS = 0.95;
	SPECULAR = 0.2;
	EMISSION = col * veg_fill_amount();
}
