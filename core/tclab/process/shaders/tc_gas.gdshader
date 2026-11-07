// Gas moving through a volume (TC Process Lab): wisps of fog that drift
// along the tube at the gas's own speed. The mesh's UV.x is distance along
// the path (m) and UV.y the angle round it (0..1); `phase` is how far the
// gas has moved (m, integrated on the lab's clock so it stops when the lab
// pauses), `swirl` a slow cosmetic churn on the same clock.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

uniform vec4 gas_color : source_color = vec4(0.92, 0.95, 1.0, 1.0);
uniform float density = 0.3;
uniform float phase = 0.0;
uniform float swirl = 0.0;
uniform float cell_m = 0.04;
uniform vec4 cut_plane = vec4(0.0, 0.0, 1.0, 1.0e6);

varying vec3 v_world;

float hash3(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.11, 0.17, 0.13));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float vnoise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash3(i), hash3(i + vec3(1, 0, 0)), f.x),
			mix(hash3(i + vec3(0, 1, 0)), hash3(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash3(i + vec3(0, 0, 1)), hash3(i + vec3(1, 0, 1)), f.x),
			mix(hash3(i + vec3(0, 1, 1)), hash3(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (dot(v_world, cut_plane.xyz) > cut_plane.w) {
		discard;
	}
	float a = UV.y * 6.2831853;
	vec3 q = vec3((UV.x - phase) / cell_m, cos(a) * 1.6, sin(a) * 1.6 + swirl);
	float n = vnoise(q) * 0.6 + vnoise(q * 2.3 + vec3(3.1, 1.7, swirl * 0.5)) * 0.4;
	float rim = pow(1.0 - clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0), 1.4);
	ALBEDO = gas_color.rgb;
	ALPHA = clamp(density * (0.25 + 0.95 * n) * (0.5 + 0.5 * rim), 0.0, 0.9);
}
