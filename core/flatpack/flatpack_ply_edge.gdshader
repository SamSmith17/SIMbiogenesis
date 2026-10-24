shader_type spatial;
render_mode cull_disabled;

// Plywood edge: the cut face of a sheet shows its plies. UV.y runs across the
// thickness (0 = one face, 1 = the other), UV.x along the edge in inches.
// Alternate plies are cross-grain and read a touch darker; the glue lines
// between them are thin dark bands.

uniform vec4 face_color : source_color = vec4(0.80, 0.66, 0.42, 1.0);
uniform int plies = 5;
uniform float glue_width = 0.07;
uniform float roughness_value = 0.85;

float hash11(float p) {
	return fract(sin(p * 127.1) * 43758.5453);
}

void fragment() {
	float n = float(max(plies, 1));
	float k = UV.y * n;
	float ply = floor(k);
	float f = fract(k);
	float glue = 1.0 - smoothstep(0.0, glue_width, f) * smoothstep(1.0, 1.0 - glue_width, f);
	vec3 base = face_color.rgb;
	// Cross-grain plies a little darker, with a faint end-grain speckle.
	float cross = mod(ply, 2.0);
	vec3 col = base * mix(1.0, 0.86, cross);
	float speck = hash11(floor(UV.x * 24.0) + ply * 31.0);
	col *= mix(0.95, 1.04, speck * cross);
	col = mix(col, base * 0.45, glue * 0.85);
	ALBEDO = col;
	ROUGHNESS = roughness_value;
	SPECULAR = 0.3;
}
