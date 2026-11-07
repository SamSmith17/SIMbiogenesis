// A tri-clamp part cut open by the section plane (TC Process Lab).
// Everything on the far side of `cut_plane` (dot(p, n) > w, world space) is
// discarded; the back faces seen through the cut are painted as a flat cut
// face (the classic cap trick), so a wall reads as solid steel without the
// geometry being rebuilt. `tint` colours a part by its temperature, `glow`
// makes a hot element shine.
shader_type spatial;
render_mode cull_disabled;

uniform vec4 albedo : source_color = vec4(0.80, 0.81, 0.83, 1.0);
uniform float metallic = 0.6;
uniform float roughness = 0.35;
uniform vec4 cut_plane = vec4(0.0, 0.0, 1.0, 1.0e6);
uniform vec3 cap_color : source_color = vec3(0.58, 0.59, 0.61);
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
	vec3 base = mix(albedo.rgb, tint.rgb, tint.a);
	if (FRONT_FACING) {
		ALBEDO = base;
		METALLIC = metallic;
		ROUGHNESS = roughness;
	} else {
		ALBEDO = mix(cap_color, tint.rgb, tint.a * 0.7);
		METALLIC = 0.15;
		ROUGHNESS = 0.75;
		NORMAL = normalize((VIEW_MATRIX * vec4(cut_plane.xyz, 0.0)).xyz);
	}
	EMISSION = glow.rgb * glow.a * 2.5;
}
