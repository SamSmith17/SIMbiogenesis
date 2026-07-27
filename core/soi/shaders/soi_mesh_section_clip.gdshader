shader_type spatial;
// Lightweight StandardMaterial stand-in that honors SoI CT section cutaway
// so placed GLBs (hydroturbine / culvert) can be midplane-sliced in Elev / Lab.
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// Inline SoI clip (same logic as soi_clip.gdshaderinc). Dynamic ShaderMaterial
// compile was failing on the include's global uniforms in some boot orders.
global uniform vec4 soi_center_radius;
global uniform float soi_clip_enabled;
global uniform vec4 soi_section_plane;
global uniform vec4 soi_section_normal;

uniform vec4 albedo_color : source_color = vec4(0.65, 0.67, 0.70, 1.0);
uniform sampler2D albedo_texture : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float metallic : hint_range(0.0, 1.0) = 0.2;
uniform float roughness : hint_range(0.0, 1.0) = 0.55;
uniform vec4 emission_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy = 0.0;

varying vec3 v_world_pos;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (soi_clip_enabled >= 0.5) {
		if (distance(v_world_pos, soi_center_radius.xyz) > soi_center_radius.w) {
			discard;
		}
		if (soi_section_plane.w > 0.5) {
			vec3 to_p = v_world_pos - soi_section_plane.xyz;
			if (dot(to_p, soi_section_normal.xyz) > 0.0) {
				discard;
			}
		}
	}
	vec4 tex = texture(albedo_texture, UV);
	ALBEDO = albedo_color.rgb * tex.rgb;
	ALPHA = albedo_color.a * tex.a;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	EMISSION = emission_color.rgb * emission_energy;
	// Interior faces after the midplane cut need a readable normal.
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
}
