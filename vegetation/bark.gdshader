// Opaque bark cards for deciduous trunks and forest-zone trunk instances.
shader_type spatial;
render_mode cull_disabled;

#include "res://vegetation/veg_lighting.gdshaderinc"
#include "res://vegetation/wind_vertex.gdshaderinc"
#include "res://vegetation/veg_growth.gdshaderinc"

#include "res://core/soi/shaders/soi_clip.gdshaderinc"

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform vec3  albedo_tint   : source_color = vec3(1.0);
uniform float roughness_value : hint_range(0.0, 1.0) = 0.98;
uniform float bark_ao_strength : hint_range(0.0, 1.0) = 0.28;
uniform float bark_color_jitter : hint_range(0.0, 0.2) = 0.06;
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.45;
uniform float snow_amount : hint_range(0.0, 1.0) = 0.0;
uniform float snow_depth_m = 0.0;
uniform vec3  snow_color : source_color = vec3(0.92, 0.94, 0.98);
// Night darkening (pushed by VegetationEnvironmentSync). Bark used to get NO
// night uniform while foliage crashed to 18% albedo — lit trunks poking out
// of black canopies at dusk.
uniform float night_factor : hint_range(0.0, 1.0) = 0.0;
uniform float night_darkness : hint_range(0.0, 1.0) = 0.72;

varying vec3 v_inst_pos;

// Stem radius (m) of the mature tree. Vertices inside it scale with GIRTH (a
// young stem is thin, an old one thick); branches further out scale with the
// crown so they still reach the foliage. 0 = unknown: everything follows the crown.
uniform float growth_trunk_radius = 0.0;

void vertex() {
	vec3 inst_pos = MODEL_MATRIX[3].xyz;
	float top_mask = 1.0 - UV.y;
	// Growth first, in model space, so wind bends the tree at its current size.
	float g_gen;
	vec4 g_st = veg_growth_state(INSTANCE_CUSTOM, g_gen);
	float g_radial = g_st.y;
	if (growth_trunk_radius > 0.0) {
		float stem = 1.0 - smoothstep(growth_trunk_radius * 1.2,
			growth_trunk_radius * 2.5, length(VERTEX.xz));
		g_radial = mix(g_st.y, g_st.z, stem);
	}
	VERTEX = veg_growth_apply(VERTEX, g_st.x, g_radial,
		veg_growth_generation(g_gen, INSTANCE_CUSTOM.w));
	float vert_phase = dot(VERTEX, vec3(9.1, 21.7, 6.3));
	VERTEX = apply_vegetation_wind(VERTEX, inst_pos, top_mask, vert_phase);
	v_inst_pos = inst_pos;
}

void fragment() {
	soi_clip_fragment(v_inst_pos);
	vec4 tex = texture(albedo_tex, UV);
	if (tex.a < alpha_scissor) {
		discard;
	}
	vec3 albedo = tex.rgb * albedo_tint;
	if (bark_color_jitter > 0.0) {
		float bj = fract(sin(dot(v_inst_pos.xz, vec2(12.9898, 78.233))) * 43758.5453) * 2.0 - 1.0;
		albedo *= 1.0 + bj * bark_color_jitter;
	}
	float base_ao = mix(1.0, 0.72, UV.y * bark_ao_strength);
	albedo *= base_ao;
	// (No manual back-face flip — see veg_lighting.gdshaderinc.)
	if (!FRONT_FACING) {
		albedo *= VEG_BACK_FACE;
	}
	vec3 wn = veg_world_normal(NORMAL, INV_VIEW_MATRIX);
	float bark_rough = roughness_value;
	if (snow_amount > 0.001 || snow_depth_m > 0.001) {
		float depth_t = clamp(snow_depth_m / 1.5, 0.0, 1.0);
		float up = clamp(wn.y * 0.5 + 0.5, 0.0, 1.0);
		float top = 1.0 - UV.y;
		float snow_mask = clamp((snow_amount * 0.3 + depth_t * 0.75) * (0.2 + 0.8 * up) * mix(0.4, 1.0, top), 0.0, 1.0);
		albedo = mix(albedo, snow_color, snow_mask);
		bark_rough = mix(roughness_value, 0.6, snow_mask);
	}
	albedo *= 1.0 - night_factor * night_darkness;
	ALBEDO = albedo;
	EMISSION = albedo * veg_fill_amount() * (1.0 - night_factor);
	ROUGHNESS = bark_rough;
	METALLIC = 0.0;
	SPECULAR = 0.2;
}
