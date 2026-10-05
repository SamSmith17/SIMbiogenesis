shader_type spatial;
// The last stage of a burn: the structure is already black (fire_char overlay
// at full), so its materials are swapped for this one and it is eaten away —
// noise-threshold holes with glowing edges, working down from the top.
// World space throughout, like fire_char. FireNode writes `dissolve` 0..1.
render_mode cull_disabled, specular_disabled;

uniform float dissolve = 0.0;
uniform float base_y = 0.0;
uniform float top_y = 1.0;

varying vec3 wpos;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash13(i), hash13(i + vec3(1, 0, 0)), f.x),
			mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), f.x),
			mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), f.x), f.y),
		f.z);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float n = vnoise(wpos * 1.7) * 0.6 + vnoise(wpos * 5.3) * 0.4;
	// The top goes first: thin members up high burn through before the base.
	float h = clamp((wpos.y - base_y) / max(top_y - base_y, 0.01), 0.0, 1.0);
	// The noise sits in roughly 0.15..0.85: at dissolve 1 the top is gone and
	// only scraps of the base are left for the collapse to sweep away.
	float cut = dissolve * (0.75 + h * 0.35);
	if (n < cut) {
		discard;
	}
	float edge = 1.0 - smoothstep(0.0, 0.09, n - cut);
	ALBEDO = vec3(0.012, 0.011, 0.010);
	ROUGHNESS = 1.0;
	EMISSION = vec3(1.0, 0.33, 0.05) * edge * 3.0 * step(0.001, dissolve);
}
