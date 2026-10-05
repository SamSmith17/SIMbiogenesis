shader_type spatial;
// Char overlay for a burning structure. Assigned as `material_overlay` on every
// mesh of the structure, so the model keeps its own materials and textures and
// this only darkens them: scorched brown just behind the burn front, black
// further down, with a glowing ember line along the front itself.
//
// Everything is driven in WORLD space (height of the burn front, distance from
// the ignition point), so one material serves the whole structure whatever its
// meshes' own axes or import scale are. FireNode writes the uniforms.
render_mode blend_mix, depth_draw_never, cull_disabled, specular_disabled;

uniform float front_y = -1.0e6;      // world height the fire has climbed to
uniform float soft_m = 0.5;          // width of the scorch transition
uniform vec2 ignite_xz = vec2(0.0);  // where it caught
uniform float reach_m = 1.0e6;       // how far round the base it has spread
uniform float char_all = 0.0;        // 0..1: the whole structure going black
uniform float ember = 1.0;           // 0 once the fire is out

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
	// A ragged front: fire does not climb as a level line.
	float n = (vnoise(wpos * 2.3) - 0.5) * 2.0 + (vnoise(wpos * 7.1) - 0.5) * 0.6;
	float lateral = smoothstep(reach_m + 1.5, reach_m - 0.5, distance(wpos.xz, ignite_xz));
	float depth = (front_y - wpos.y) + n * soft_m;      // metres below the front
	float scorch = smoothstep(0.0, soft_m, depth) * lateral;
	float black = smoothstep(soft_m, soft_m * 4.0, depth) * lateral;
	scorch = max(scorch, char_all);
	black = max(black, char_all);

	ALBEDO = mix(vec3(0.17, 0.09, 0.045), vec3(0.012, 0.011, 0.010), black);
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	// Embers: brightest right at the front, dying back into the black.
	float glow = smoothstep(-soft_m * 0.4, soft_m * 0.3, depth)
		* (1.0 - smoothstep(soft_m * 0.3, soft_m * 2.2, depth)) * lateral;
	// A few slow-breathing ember cracks in the fresh char, fading out with
	// depth: old char is dead black, not a field of orange spots.
	float fresh = 1.0 - smoothstep(soft_m * 2.0, soft_m * 9.0, depth);
	float crackle = smoothstep(0.74, 0.92, vnoise(wpos * 6.0 + vec3(0.0, TIME * 0.12, 0.0)));
	glow = glow * (0.55 + 0.45 * sin(TIME * 5.0 + wpos.x * 3.0 + wpos.z * 2.0))
		+ black * crackle * 0.3 * fresh * lateral * (1.0 - char_all);
	// Once the whole structure is charred there is no front left to glow.
	glow *= 1.0 - char_all * 0.85;
	EMISSION = vec3(1.0, 0.30, 0.04) * glow * 2.6 * ember;
	ALPHA = clamp(scorch * mix(0.55, 0.97, black) + glow * 0.3 * ember, 0.0, 1.0);
}
