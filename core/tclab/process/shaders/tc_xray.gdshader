// A tri-clamp part as a see-through ghost (TC Process Lab X-ray, and glass
// in the section view): faint where it faces you, brighter at the rim, so the
// contents inside read through it. Takes the same cut plane, tint and glow as
// tc_section.gdshader.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back;

uniform vec4 ghost : source_color = vec4(0.62, 0.76, 0.90, 1.0);
uniform float base_alpha = 0.05;
uniform float rim_alpha = 0.50;
uniform float rim_power = 2.6;
uniform vec4 cut_plane = vec4(0.0, 0.0, 1.0, 1.0e6);
instance uniform vec4 tint : source_color = vec4(0.0);
instance uniform vec4 glow : source_color = vec4(0.0);

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (dot(v_world, cut_plane.xyz) > cut_plane.w) {
		discard;
	}
	float f = pow(1.0 - clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0), rim_power);
	ALBEDO = mix(ghost.rgb, tint.rgb, tint.a) + glow.rgb * glow.a;
	ALPHA = clamp(base_alpha + rim_alpha * f + tint.a * 0.12 + glow.a * 0.6, 0.0, 1.0);
}
