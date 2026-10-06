shader_type spatial;
// The last stage of a burn: the structure is already black (fire_char overlay
// at full), so its materials are swapped for this one and it is eaten away —
// noise-threshold holes with glowing edges, working down from the top.
// World space throughout, like fire_char. FireNode writes `dissolve` 0..1.
//
// At about three quarters consumed the structure FAILS: FireNode runs
// `collapse` 0..1 and what is left drops into the pile at its base. The burn
// pattern is keyed on where a piece WAS (`wpos`, taken before the fall), so
// the holes ride down with it instead of swimming across it.
render_mode cull_disabled, specular_disabled, world_vertex_coords;

uniform float dissolve = 0.0;
uniform float base_y = 0.0;
uniform float top_y = 1.0;
uniform float collapse = 0.0;                 // 0 standing .. 1 down in the pile
uniform vec2 pile_xz = vec2(0.0);             // centre of the pile footprint
uniform vec2 pile_radius = vec2(1.0e6);       // its half-extents on x / z
uniform float pile_h = 0.4;                   // how high the heap stands

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
	wpos = VERTEX;  // world space (world_vertex_coords), before the fall
	if (collapse > 0.0) {
		// Members do not all let go at once: a low-frequency lag, so neighbouring
		// vertices travel together and the frame crumples rather than shears.
		float lag = vnoise(wpos * 0.45) * 0.35;
		float t = clamp(collapse * 1.35 - lag, 0.0, 1.0);
		t *= t;  // it falls, accelerating
		float h = max(wpos.y - base_y, 0.0);
		float heap = min(h, pile_h * (0.25 + 0.6 * vnoise(wpos * 1.3)));
		VERTEX.y = base_y + mix(h, heap, t);
		// Anything overhanging the base lands inside the footprint.
		vec2 d = (wpos.xz - pile_xz) / max(pile_radius, vec2(0.01));
		float dl = length(d);
		if (dl > 0.85) {
			vec2 inside = pile_xz + d / dl * 0.85 * pile_radius;
			VERTEX.xz = mix(wpos.xz, inside, t);
		}
	}
}

void fragment() {
	float n = vnoise(wpos * 1.7) * 0.6 + vnoise(wpos * 5.3) * 0.4;
	// The top goes first: thin members up high burn through before the base.
	float h = clamp((wpos.y - base_y) / max(top_y - base_y, 0.01), 0.0, 1.0);
	// The noise sits in roughly 0.06..0.95. Measured over a uniform surface:
	// dissolve 0.65 = 75 % gone (where FireNode collapses it), 1.0 = 99.7 %,
	// and by 1.35 nothing is left.
	float cut = dissolve * (0.75 + h * 0.35);
	if (n < cut) {
		discard;
	}
	float edge = 1.0 - smoothstep(0.0, 0.09, n - cut);
	ALBEDO = vec3(0.012, 0.011, 0.010);
	ROUGHNESS = 1.0;
	EMISSION = vec3(1.0, 0.33, 0.05) * edge * 3.0 * step(0.001, dissolve);
}
