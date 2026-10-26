shader_type spatial;
render_mode cull_disabled;

// A toothed timing belt. The ribbon's UV.x is the arc length along the loop
// in metres and UV.y says which face this is (0..1 the toothed inside,
// 1..2 the smooth back, 2..3 the edges, where the tooth profile shows).
// `offset_m` is how far the belt has travelled: the builder sets it from the
// motor's displacement, so the teeth march with the carriage and the
// pulleys they wrap turn in step.

uniform vec3 albedo : source_color = vec3(0.07, 0.07, 0.08);
uniform float pitch_m = 0.002;
uniform float offset_m = 0.0;
uniform float tooth_depth = 0.75;

void fragment() {
	float t = fract((UV.x + offset_m) / pitch_m);
	float tooth = smoothstep(0.08, 0.28, t) * (1.0 - smoothstep(0.62, 0.82, t));
	float face = UV.y;
	float strength = face < 1.0 ? 1.0 : (face < 2.0 ? 0.1 : 0.85);
	float shade = 1.0 - tooth_depth * strength * 0.55 * (1.0 - tooth);
	ALBEDO = albedo * shade;
	ROUGHNESS = 0.92;
	METALLIC = 0.0;
	SPECULAR = 0.25;
}
