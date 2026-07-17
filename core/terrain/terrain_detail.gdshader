shader_type spatial;

// Terrain drape with a high-resolution centre patch (ROADMAP Pillar 1).
// extent_ratio = terrain_extent_m / detail_extent_m (e.g. 30 km / 1 km = 30).
//
// Coarse 30 km mesh: UV 0..1 spans full terrain; detail sampled via duv remap.
// Detail 1 km patch mesh (patch_mesh): UV 0..1 spans the patch; detail_tex uses
// UV directly; base_tex uses global_uv remap onto the 30 km drape.
//
// Mesh UVs are lon/lat-linear (GeoMath tangent plane). ESRI drapes are
// Mercator-linear between the same bbox corners — sample via
// equirect→Mercator so OSM buildings stay registered to the photo.

render_mode cull_disabled, diffuse_lambert, specular_disabled;

uniform sampler2D base_tex : source_color, filter_linear_mipmap;
uniform sampler2D detail_tex : source_color, filter_linear_mipmap;
uniform bool use_base = true;
uniform vec3 base_color : source_color = vec3(0.45, 0.42, 0.38);
uniform float extent_ratio = 30.0;
uniform float feather = 0.06;
uniform bool patch_mesh = false;
uniform bool use_detail = false;
uniform bool hide_detail_region = false;
uniform bool hide_centre_region = false;
// bbox = (west, east, south, north) degrees. z-component unused flags via w.
uniform vec4 base_bbox = vec4(-1.0, 1.0, -1.0, 1.0);
uniform vec4 detail_bbox = vec4(-1.0, 1.0, -1.0, 1.0);
uniform bool correct_base_mercator = false;
uniform bool correct_detail_mercator = false;
// Seasonal ground snow (driven live by TerrainLoader from weather data).
uniform float snow_amount : hint_range(0.0, 1.0) = 0.0;
uniform float snow_depth_m = 0.0; // modelled pack depth — fakes raised surface on flats
uniform vec3 snow_color : source_color = vec3(0.90, 0.93, 0.98);
// Steep terrain sheds snow: below snow_slope_min it stays bare; above
// snow_slope_max it holds fully. Values are world-up dot (1 = flat ground).
uniform float snow_slope_min : hint_range(0.0, 1.0) = 0.45;
uniform float snow_slope_max : hint_range(0.0, 1.0) = 0.80;

#include "res://core/soi/shaders/soi_clip.gdshaderinc"

varying vec3 v_world_normal;
varying vec3 v_world_pos;

float _asinh(float x) {
	return log(x + sqrt(x * x + 1.0));
}

// Equirectangular UV (lon/lat-linear over bbox) → Mercator UV into the drape.
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

vec3 sample_drape(sampler2D tex, vec2 equirect_uv, vec4 bbox, bool correct) {
	vec2 suv = correct ? equirect_to_mercator_uv(equirect_uv, bbox) : equirect_uv;
	return texture(tex, suv).rgb;
}

void vertex() {
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	soi_clip_fragment(v_world_pos);
	vec2 uv = UV;
	vec3 col;

	if (patch_mesh) {
		vec2 global_uv = (uv - vec2(0.5)) / extent_ratio + vec2(0.5);
		vec3 base = use_base ? sample_drape(base_tex, global_uv, base_bbox, correct_base_mercator) : base_color;
		vec3 detail = use_detail ? sample_drape(detail_tex, uv, detail_bbox, correct_detail_mercator) : base;
		float edge = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
		float blend = smoothstep(0.0, feather, edge);
		col = use_detail ? mix(base, detail, blend) : base;
	} else {
		vec2 global_uv = uv;
		vec3 base = use_base ? sample_drape(base_tex, global_uv, base_bbox, correct_base_mercator) : base_color;
		col = base;
		vec2 duv = (uv - vec2(0.5)) * extent_ratio + vec2(0.5);
		float blend = 0.0;
		if (use_detail && duv.x > 0.0 && duv.x < 1.0 && duv.y > 0.0 && duv.y < 1.0) {
			vec3 detail = sample_drape(detail_tex, duv, detail_bbox, correct_detail_mercator);
			float edge = min(min(duv.x, 1.0 - duv.x), min(duv.y, 1.0 - duv.y));
			blend = smoothstep(0.0, feather, edge);
			col = mix(base, detail, blend);
		}
		// When DetailGround covers the hi-res square, discard coarse fragments there
		// so the two displaced meshes do not z-fight or double-draw the drape.
		if (hide_centre_region || (hide_detail_region && blend > 0.02)) {
			vec2 duv_hide = (uv - vec2(0.5)) * extent_ratio + vec2(0.5);
			if (duv_hide.x > 0.0 && duv_hide.x < 1.0 && duv_hide.y > 0.0 && duv_hide.y < 1.0) {
				float edge_hide = min(min(duv_hide.x, 1.0 - duv_hide.x), min(duv_hide.y, 1.0 - duv_hide.y));
				if (hide_centre_region) {
					discard;
				} else if (smoothstep(0.0, feather, edge_hide) > 0.02) {
					discard;
				}
			}
		}
	}

	float rough = 1.0;
	if (snow_amount > 0.001 || snow_depth_m > 0.001) {
		float depth_t = clamp(snow_depth_m / 1.5, 0.0, 1.0);
		// Flat ground accumulates; steep faces shed. Small spatial break-up so
		// the snow line is not a perfectly uniform sheet.
		float slope_hold = smoothstep(snow_slope_min, snow_slope_max, clamp(v_world_normal.y, 0.0, 1.0));
		vec2 ncell = floor(v_world_pos.xz / 12.0);
		float n = fract(sin(dot(ncell, vec2(45.2, 17.9))) * 43758.5453) * 2.0 - 1.0;
		float cover_strength = clamp(snow_amount * 0.35 + depth_t * 0.75, 0.0, 1.0);
		float cover = clamp(cover_strength * (0.40 + 0.60 * slope_hold) + n * 0.05 * cover_strength, 0.0, 1.0);
		// Deep packs read brighter / softer on horizontal terrain.
		vec3 pack_col = mix(snow_color, vec3(0.96, 0.98, 1.0), depth_t * slope_hold * 0.35);
		col = mix(col, pack_col, cover);
		rough = mix(1.0, mix(0.72, 0.88, depth_t), cover);
	}

	ALBEDO = col;
	ROUGHNESS = rough;
	METALLIC = 0.0;
}
