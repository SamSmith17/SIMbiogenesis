// Liquid standing in a volume (TC Process Lab): the same tube as the gas,
// drawn only below the liquid's level (`level_y`, world). `ripple` stirs the
// surface band when the pool boils.
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_disabled;

uniform vec4 liquid_color : source_color = vec4(0.45, 0.62, 0.78, 0.8);
uniform float level_y = -1.0e6;
uniform float ripple = 0.0;
uniform float swirl = 0.0;
uniform vec4 cut_plane = vec4(0.0, 0.0, 1.0, 1.0e6);

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (dot(v_world, cut_plane.xyz) > cut_plane.w) {
		discard;
	}
	float wave = ripple * 0.004 * sin(v_world.x * 90.0 + swirl * 7.0) * sin(v_world.z * 80.0 - swirl * 5.0);
	if (v_world.y > level_y + wave) {
		discard;
	}
	float edge = smoothstep(0.004, 0.0, abs(v_world.y - level_y - wave));
	ALBEDO = mix(liquid_color.rgb, vec3(0.95), edge * 0.5);
	ROUGHNESS = 0.08;
	METALLIC = 0.0;
	SPECULAR = 0.6;
	ALPHA = clamp(liquid_color.a + edge * 0.2, 0.0, 1.0);
}
