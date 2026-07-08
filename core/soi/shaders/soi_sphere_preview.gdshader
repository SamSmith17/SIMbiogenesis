shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded;

uniform vec4 rim_color : source_color = vec4(0.133, 0.827, 0.933, 0.22);
uniform float fill_alpha : hint_range(0.0, 0.5) = 0.04;

void fragment() {
	float ndv = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float rim = pow(1.0 - ndv, 2.5);
	float a = rim_color.a * (fill_alpha + rim * 0.65);
	vec3 col = rim_color.rgb * (0.35 + rim * 0.85);
	ALBEDO = col;
	ALPHA = a;
}
