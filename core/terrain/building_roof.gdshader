shader_type spatial;

// OSM building roofs: procedural staggered shingle courses on pitched faces,
// membrane/gravel on flat ones. Mesh contract (BuildingBuilder): UV.x =
// metres along the eave (course direction), UV.y = true metres up the slope,
// so courses stay level and square on gables/hips/skillions; COLOR.rgb =
// per-building roof tint, COLOR.a = 1 pitched / 0 flat; UV2 = geo-registered
// plan position over the central ortho square (0..1 inside the patch — see
// BuildingBuilder.ORTHO_HALF_EXTENT_M) for sampling the real aerial photo.
render_mode cull_disabled, diffuse_lambert, specular_schlick_ggx;

uniform float course_height_m : hint_range(0.10, 0.40) = 0.18;
uniform float tab_width_m : hint_range(0.15, 0.60) = 0.30;
uniform float course_shadow : hint_range(0.0, 1.0) = 0.50;
uniform float tab_jitter : hint_range(0.0, 0.30) = 0.09;
uniform float roof_roughness : hint_range(0.3, 1.0) = 0.90;

// Ortho projection: when use_ortho is on, roofs whose UV2 lies inside the patch
// sample the real satellite photo instead of the tinted procedural pattern; the
// procedural shade stays layered on top (ortho_relief) so shingle courses /
// membrane grain still read up close. ortho_uv_scale remaps UV2 when the bound
// texture covers a LARGER square than the hyper patch (detail-drape fallback:
// scale = hyper_half / detail_half).
uniform sampler2D ortho_tex : source_color, filter_linear_mipmap;
uniform bool use_ortho = false;
uniform float ortho_blend : hint_range(0.0, 1.0) = 1.0;
uniform float ortho_relief : hint_range(0.0, 1.0) = 0.35;
uniform float ortho_uv_scale = 1.0;
// (west, east, south, north) of the bound ortho texture; Mercator sample fix.
uniform vec4 ortho_bbox = vec4(-1.0, 1.0, -1.0, 1.0);
uniform bool correct_ortho_mercator = false;
uniform float snow_amount : hint_range(0.0, 1.0) = 0.0;
uniform float snow_depth_m = 0.0;
uniform vec3 snow_color : source_color = vec3(0.90, 0.93, 0.98);

#include "res://core/soi/shaders/soi_clip.gdshaderinc"

varying vec2 v_geo_uv;
varying vec3 v_world_pos;
varying vec3 v_world_normal;

float hash2(vec2 p) {
	return fract(sin(dot(p, vec2(41.3, 289.1))) * 43758.5453);
}

float _asinh(float x) {
	return log(x + sqrt(x * x + 1.0));
}

vec2 equirect_to_mercator_uv(vec2 uv, vec4 bbox_wesn) {
	float lat = mix(bbox_wesn.w, bbox_wesn.z, uv.y);
	lat = clamp(lat, -85.05112878, 85.05112878);
	float lat_n = clamp(bbox_wesn.w, -85.05112878, 85.05112878);
	float lat_s = clamp(bbox_wesn.z, -85.05112878, 85.05112878);
	float my = _asinh(tan(radians(lat)));
	float my_n = _asinh(tan(radians(lat_n)));
	float my_s = _asinh(tan(radians(lat_s)));
	float v = (my_n - my) / max(my_n - my_s, 1e-12);
	return vec2(uv.x, v);
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

void vertex() {
	v_geo_uv = UV2;
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	soi_clip_fragment(v_world_pos);
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
	vec3 base_rgb = COLOR.rgb * shade;

	if (use_ortho) {
		// Remap the hyper-patch geo UV into the bound texture's square, inset
		// slightly so compressed-mip edge bleed from neighbouring ground pixels
		// never lands on a roof.
		vec2 ouv = (v_geo_uv - 0.5) * ortho_uv_scale + 0.5;
		if (all(greaterThan(ouv, vec2(0.005))) && all(lessThan(ouv, vec2(0.995)))) {
			vec2 suv = correct_ortho_mercator ? equirect_to_mercator_uv(ouv, ortho_bbox) : ouv;
			vec3 photo = texture(ortho_tex, suv).rgb
				* mix(1.0, shade, ortho_relief);
			base_rgb = mix(base_rgb, photo, ortho_blend);
		}
	}

	ALBEDO = base_rgb;
	ROUGHNESS = roof_roughness;
	if (snow_amount > 0.001 || snow_depth_m > 0.001) {
		float depth_t = clamp(snow_depth_m / 1.5, 0.0, 1.0);
		float up = clamp(v_world_normal.y, 0.0, 1.0);
		// Flat roofs load deepest; pitched still hold snow on the upward face.
		float hold = smoothstep(0.20, 0.88, up) * mix(1.0, 0.55, pitched);
		float cov = clamp(snow_amount * 0.45 + depth_t * 0.85, 0.0, 1.0) * hold;
		ALBEDO = mix(ALBEDO, mix(snow_color, vec3(0.97, 0.99, 1.0), depth_t * 0.4), cov);
		ROUGHNESS = mix(ROUGHNESS, 0.9, cov);
	}
	METALLIC = 0.0;
	SPECULAR = 0.2;
}
