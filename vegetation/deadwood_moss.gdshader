shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled;

// Moss overlay for imported stump models (VegDeadwood, material_overlay):
// the model keeps its own materials and this pass paints a patchy green pelt
// on whatever faces up — the cut top and the upper root flare — the way an
// old-growth stump in a wet forest wears it. Linear colours.

#include "res://vegetation/veg_lighting.gdshaderinc"

uniform vec3 moss_color = vec3(0.070, 0.135, 0.020);
uniform vec3 moss_dry = vec3(0.105, 0.125, 0.038);
uniform float moss_amount : hint_range(0.0, 1.0) = 0.8;

varying vec3 v_world;

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
}

void fragment() {
	float blot = vnoise(v_world.xz * 1.3) * 0.6 + vnoise(v_world.xz * 4.1 + 9.0) * 0.4;
	// Face normal from derivatives: imported stumps are often double-sided or
	// wound inside out, and "up" must be found either way.
	float up = abs(normalize(cross(dFdx(v_world), dFdy(v_world))).y) + (blot - 0.5) * 0.8;
	float a = smoothstep(0.15, 0.6, up) * moss_amount;
	if (a < 0.01) {
		discard;
	}
	vec3 col = mix(moss_dry, moss_color, vnoise(v_world.xz * 3.7 + 2.0));
	ALBEDO = col;
	ALPHA = clamp(a, 0.0, 1.0);
	ROUGHNESS = 1.0;
	SPECULAR = 0.15;
	EMISSION = col * veg_fill_amount();
}
