shader_type spatial;

// OSM building roofs: procedural staggered shingle courses on pitched faces,
// membrane/gravel on flat ones. Mesh contract (BuildingBuilder): UV.x =
// metres along the eave (course direction), UV.y = true metres up the slope,
// so courses stay level and square on gables/hips/skillions; COLOR.rgb =
// per-building roof tint, COLOR.a = 1 pitched / 0 flat.
render_mode cull_disabled, diffuse_lambert, specular_schlick_ggx;

uniform float course_height_m : hint_range(0.10, 0.40) = 0.18;
uniform float tab_width_m : hint_range(0.15, 0.60) = 0.30;
uniform float course_shadow : hint_range(0.0, 1.0) = 0.50;
uniform float tab_jitter : hint_range(0.0, 0.30) = 0.09;
uniform float roof_roughness : hint_range(0.3, 1.0) = 0.90;

float hash2(vec2 p) {
	return fract(sin(dot(p, vec2(41.3, 289.1))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash2(i);
	float b = hash2(i + vec2(1.0, 0.0));
	float c = hash2(i + vec2(0.0, 1.0));
	float d = hash2(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void fragment() {
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}

	float pitched = step(0.5, COLOR.a);

	// Shingle courses: odd courses offset half a tab, per-tab value jitter, a
	// butt shadow along each course's bottom edge and faint tab gaps.
	float band = UV.y / course_height_m;
	float cidx = floor(band);
	float fy = fract(band);
	float aa = fwidth(band) * 1.5 + 1e-4;
	float tab = UV.x / tab_width_m + mod(cidx, 2.0) * 0.5;
	float tidx = floor(tab);
	float fx = fract(tab);

	float jit = (hash2(vec2(tidx, cidx)) - 0.5) * 2.0 * tab_jitter;
	float butt = 1.0 - course_shadow * smoothstep(0.14 + aa, 0.0, fy);
	float gap = 1.0 - 0.3 * course_shadow
		* (smoothstep(0.04, 0.0, fx) + smoothstep(1.0 - 0.04, 1.0, fx));
	float shingle = (1.0 + jit) * butt * gap;

	// Collapse to plain tint before the pattern aliases at distance.
	float det = clamp(fwidth(band) * 2.0, 0.0, 1.0);
	shingle = mix(shingle, 1.0, det);

	// Flat roofs: fine gravel grain + broad weather patches.
	float membrane = (0.92 + 0.16 * vnoise(UV * 6.0))
		* (1.0 + (vnoise(UV * 0.35) - 0.5) * 0.10);

	float shade = mix(membrane, shingle, pitched);
	ALBEDO = COLOR.rgb * shade;
	ROUGHNESS = roof_roughness;
	METALLIC = 0.0;
	SPECULAR = 0.2;
}
