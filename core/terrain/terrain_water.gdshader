shader_type spatial;

// Flat OSM water — level mesh + local ReflectionProbe cubemaps (placed per lake in
// WaterBuilder). Fresnel ramps specular/roughness so grazing angles pick up sky and
// shoreline trees; micro-normals break up the mirror without folding the surface.
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_lambert, specular_schlick_ggx;

uniform vec4 deep_color : source_color = vec4(0.02, 0.10, 0.17, 1.0);
uniform vec4 shallow_color : source_color = vec4(0.12, 0.32, 0.40, 1.0);
uniform float water_alpha : hint_range(0.4, 1.0) = 0.90;
uniform float wave_speed = 0.45;
uniform float wave_scale = 0.05;
uniform float ripple_strength : hint_range(0.0, 0.5) = 0.10;
uniform float base_roughness : hint_range(0.0, 0.25) = 0.04;
uniform float gloss_roughness : hint_range(0.0, 0.15) = 0.015;
uniform float base_specular : hint_range(0.0, 1.0) = 0.45;
uniform float gloss_specular : hint_range(0.0, 1.0) = 0.92;

vec3 wave_normal(vec2 p, float t) {
	vec2 a = p * wave_scale + vec2(0.031, 0.017) * t;
	vec2 b = p * wave_scale * 1.73 + vec2(-0.024, 0.029) * t;
	float dx = (cos(a.x * 6.2831) + 0.7 * cos(b.x * 6.2831)) * ripple_strength;
	float dz = (cos(a.y * 6.2831) + 0.7 * cos(b.y * 6.2831)) * ripple_strength;
	return normalize(vec3(dx, 1.0, dz));
}

void fragment() {
	float t = TIME * wave_speed;
	vec3 n_world = wave_normal(VERTEX.xz, t);
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);

	float ndv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fres = pow(1.0 - ndv, 3.5);

	ALBEDO = mix(deep_color.rgb, shallow_color.rgb, fres * 0.42);
	ROUGHNESS = mix(base_roughness, gloss_roughness, fres);
	SPECULAR = mix(base_specular, gloss_specular, fres);
	METALLIC = 0.0;
	ALPHA = water_alpha;
}
