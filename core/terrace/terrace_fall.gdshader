shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

// Water spilling over a paddy's lip and running down the riser to the next
// (TerraceRuntime). A ribbon: UV.x across 0..1, UV.y metres along. The foam
// streaks run down it; `flow` (0..1, set per ribbon from the spill rate)
// fades it in and widens the white water.

instance uniform float flow = 0.0;
uniform vec3 water : source_color = vec3(0.62, 0.72, 0.72);
uniform vec3 foam : source_color = vec3(0.94, 0.96, 0.95);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(41.3, 289.1))) * 15731.743);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

void fragment() {
	float across = abs(UV.x - 0.5) * 2.0;
	float edge = 1.0 - smoothstep(0.35 + 0.4 * flow, 1.0, across);
	float s = vnoise(vec2(UV.x * 6.0, UV.y * 2.5 - TIME * 3.2));
	float s2 = vnoise(vec2(UV.x * 13.0, UV.y * 6.0 - TIME * 5.0));
	float white = smoothstep(0.45, 0.85, s * 0.6 + s2 * 0.4);
	ALBEDO = mix(water, foam, white * (0.5 + 0.5 * flow));
	ROUGHNESS = 0.2;
	SPECULAR = 0.5;
	ALPHA = edge * clamp(flow * 1.4, 0.0, 0.92) * (0.55 + 0.45 * white);
}
