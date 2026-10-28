shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// Clip-plane reveal for Precious Plastic beam extrusion. Fragments on the
// inward (machine) side of the die plane are discarded so the stick only
// appears once it has left the mold mouth.

uniform vec4 albedo : source_color = vec4(0.22, 0.62, 0.58, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.55;
uniform float metallic : hint_range(0.0, 1.0) = 0.05;
uniform vec3 clip_origin = vec3(0.0);
uniform vec3 clip_normal = vec3(1.0, 0.0, 0.0);
uniform bool clip_enabled = true;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (clip_enabled) {
		float side = dot(world_pos - clip_origin, normalize(clip_normal));
		if (side < 0.0) {
			discard;
		}
	}
	ALBEDO = albedo.rgb;
	ROUGHNESS = roughness;
	METALLIC = metallic;
}
