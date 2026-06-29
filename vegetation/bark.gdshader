// Opaque bark cards for deciduous trunks and forest-zone trunk instances.
shader_type spatial;
render_mode cull_disabled;

#include "res://vegetation/wind_vertex.gdshaderinc"

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform vec3  albedo_tint   : source_color = vec3(1.0);
uniform float roughness_value : hint_range(0.0, 1.0) = 0.98;
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.45;

void vertex() {
	vec3 inst_pos = MODEL_MATRIX[3].xyz;
	float top_mask = 1.0 - UV.y;
	float vert_phase = dot(VERTEX, vec3(9.1, 21.7, 6.3));
	VERTEX = apply_vegetation_wind(VERTEX, inst_pos, top_mask, vert_phase);
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);
	if (tex.a < alpha_scissor) {
		discard;
	}
	vec3 albedo = tex.rgb * albedo_tint;
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
		albedo *= 0.35;
	}
	ALBEDO = albedo;
	ROUGHNESS = roughness_value;
	METALLIC = 0.0;
}
