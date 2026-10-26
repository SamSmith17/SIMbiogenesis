shader_type spatial;
render_mode cull_disabled;

// A helical thread painted onto a plain cylinder: lead screws, the slit of
// a flexible coupler and the coils of a bed-levelling spring. The part is
// built ALONG ITS LOCAL +Y with UV.x = angle round the axis / TAU and
// UV.y = metres along it (GantryLabDetail.lathe with uv), so the crest of a
// `starts`-start thread of lead `lead_m` lies where
//     fract(starts * (UV.y / lead_m - UV.x)) == 0
// and the whole screw turns by rotating the node — the helix really climbs.
// A fake normal tilted along the axis gives the groove its shading, so a
// 500 mm Tr8 costs 16 sides × 1 segment instead of a modelled thread.

uniform vec3 albedo : source_color = vec3(0.78, 0.79, 0.8);
uniform float metallic = 0.85;
uniform float roughness = 0.4;
uniform float lead_m = 0.008;
uniform int starts = 4;
uniform float duty = 0.5;     // groove share of one pitch (0.12 = a coupler's slit)
uniform float depth = 0.7;    // how dark / how tilted the groove reads

varying vec3 v_axis_view;

void vertex() {
	v_axis_view = normalize((MODELVIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
}

void fragment() {
	float phase = fract(float(starts) * (UV.y / lead_m - UV.x));
	float tri = abs(phase * 2.0 - 1.0);
	float g = 1.0 - smoothstep(duty - 0.1, duty + 0.1, tri);
	float side = phase < 0.5 ? 1.0 : -1.0;
	NORMAL = normalize(NORMAL + v_axis_view * (side * g * depth * 0.9));
	ALBEDO = albedo * (1.0 - 0.5 * depth * g);
	METALLIC = metallic;
	ROUGHNESS = roughness + 0.25 * g;
}
