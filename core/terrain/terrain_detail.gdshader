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
// "Hyper" ortho: a small central patch at much higher ESRI zoom (the same
// texture that drapes building roofs / berms). Sharpens the core the player
// actually walks. hyper_ratio = this mesh's span / hyper patch span.
uniform sampler2D hyper_tex : source_color, filter_linear_mipmap;
uniform bool use_hyper = false;
uniform float hyper_ratio = 3.0;
uniform float hyper_feather = 0.06;
uniform vec4 hyper_bbox = vec4(-1.0, 1.0, -1.0, 1.0);
uniform bool correct_hyper_mercator = false;
// "AI hero" patch: an even smaller central square around the map origin whose
// ground has been enhanced by the Gemini image model (beats the ESRI ceiling
// where the player spawns). Overlaid ON TOP of hyper in the same feathered way.
// ai_ratio = this mesh's span / AI patch span.
uniform sampler2D ai_tex : source_color, filter_linear_mipmap;
uniform bool use_ai = false;
uniform float ai_ratio = 100.0;
uniform float ai_feather = 0.08;
uniform vec4 ai_bbox = vec4(-1.0, 1.0, -1.0, 1.0);
uniform bool correct_ai_mercator = false;
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

// -----------------------------------------------------------------------------
// Near-field ground detail (foot-level realism).
// The ESRI ortho drape tops out at ~0.25 m/px (z19), so it reads as soft blocks
// when the camera is a metre or two off the ground. Shipping games solve this
// with "material/detail blending": keep the satellite photo for macro colour but
// blend a high-frequency ground detail (albedo grain + a relief NORMAL) into the
// near field, fading out with camera distance. The normal perturbation is the key
// cue — it gives the flat photo real surface relief under the sun/moon.
// This foundation is procedural (asset-free, works offline everywhere). Real
// tiling PBR ground textures can be layered on later via the *_tex stubs below.
uniform bool near_detail_enabled = true;
// Camera-distance fade window (metres): full detail nearer than _start, gone past _end.
uniform float near_detail_start = 4.0;
uniform float near_detail_end = 30.0;
// Repeat length of the coarse grain octave (metres); a finer octave rides on top.
uniform float near_detail_tile_m = 2.5;
// How strongly the procedural relief perturbs the surface normal (0 = flat photo).
uniform float near_detail_bump : hint_range(0.0, 1.0) = 0.55;
// How strongly the albedo grain darkens/lightens the photo colour up close.
uniform float near_detail_albedo : hint_range(0.0, 1.0) = 0.35;
// --- Optional real tiling textures (disabled by default; future upgrade path) ---
uniform bool use_detail_textures = false;
uniform sampler2D detail_albedo_tex : source_color, filter_linear_mipmap, hint_default_white;
uniform sampler2D detail_normal_tex : hint_normal, filter_linear_mipmap;
uniform sampler2D detail_rough_tex : filter_linear_mipmap, hint_default_white;
uniform float detail_tex_tile_m = 2.0;
uniform float detail_tex_normal_strength : hint_range(0.0, 2.0) = 1.0;

#include "res://core/soi/shaders/soi_clip.gdshaderinc"

varying vec3 v_world_normal;
varying vec3 v_world_pos;

float _asinh(float x) {
	return log(x + sqrt(x * x + 1.0));
}

// --- Cheap value noise / fBm for procedural ground grain ---------------------
float _hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float _vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = _hash12(i);
	float b = _hash12(i + vec2(1.0, 0.0));
	float c = _hash12(i + vec2(0.0, 1.0));
	float d = _hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float _fbm(vec2 p) {
	float s = 0.0;
	float amp = 0.5;
	for (int k = 0; k < 4; k++) {
		s += amp * _vnoise(p);
		p *= 2.0;
		amp *= 0.5;
	}
	return s;
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
		// Overlay the hyper patch (sharpest) in the central hyper square.
		if (use_hyper) {
			vec2 huv = (uv - vec2(0.5)) * hyper_ratio + vec2(0.5);
			if (huv.x > 0.0 && huv.x < 1.0 && huv.y > 0.0 && huv.y < 1.0) {
				vec3 hyper = sample_drape(hyper_tex, huv, hyper_bbox, correct_hyper_mercator);
				float hedge = min(min(huv.x, 1.0 - huv.x), min(huv.y, 1.0 - huv.y));
				col = mix(col, hyper, smoothstep(0.0, hyper_feather, hedge));
			}
		}
		// AI hero patch (sharpest of all) — layered on top of hyper.
		if (use_ai) {
			vec2 auv = (uv - vec2(0.5)) * ai_ratio + vec2(0.5);
			if (auv.x > 0.0 && auv.x < 1.0 && auv.y > 0.0 && auv.y < 1.0) {
				vec3 ai = sample_drape(ai_tex, auv, ai_bbox, correct_ai_mercator);
				float aedge = min(min(auv.x, 1.0 - auv.x), min(auv.y, 1.0 - auv.y));
				col = mix(col, ai, smoothstep(0.0, ai_feather, aedge));
			}
		}
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
		// Hyper overlay for the coarse mesh (only visible where DetailGround
		// isn't covering the centre; harmless otherwise).
		if (use_hyper) {
			vec2 huv = (uv - vec2(0.5)) * hyper_ratio + vec2(0.5);
			if (huv.x > 0.0 && huv.x < 1.0 && huv.y > 0.0 && huv.y < 1.0) {
				vec3 hyper = sample_drape(hyper_tex, huv, hyper_bbox, correct_hyper_mercator);
				float hedge = min(min(huv.x, 1.0 - huv.x), min(huv.y, 1.0 - huv.y));
				col = mix(col, hyper, smoothstep(0.0, hyper_feather, hedge));
			}
		}
		// AI hero patch (sharpest of all) — layered on top of hyper.
		if (use_ai) {
			vec2 auv = (uv - vec2(0.5)) * ai_ratio + vec2(0.5);
			if (auv.x > 0.0 && auv.x < 1.0 && auv.y > 0.0 && auv.y < 1.0) {
				vec3 ai = sample_drape(ai_tex, auv, ai_bbox, correct_ai_mercator);
				float aedge = min(min(auv.x, 1.0 - auv.x), min(auv.y, 1.0 - auv.y));
				col = mix(col, ai, smoothstep(0.0, ai_feather, aedge));
			}
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

	// --- Near-field ground detail (albedo grain + relief normal) --------------
	// Fades in as the camera approaches so the flat photo reads as real ground at
	// foot level, without touching the distant look the drone view relies on.
	vec3 world_n = normalize(v_world_normal);
	if (near_detail_enabled) {
		float cam_d = distance(v_world_pos, CAMERA_POSITION_WORLD);
		float k = 1.0 - smoothstep(near_detail_start, near_detail_end, cam_d);
		if (k > 0.001) {
			vec2 wp = v_world_pos.xz;
			// Build an arbitrary but stable tangent frame around the geometric
			// normal so relief works on slopes as well as flat ground.
			vec3 up_ref = abs(world_n.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
			vec3 tan_u = normalize(cross(up_ref, world_n));
			vec3 tan_v = cross(world_n, tan_u);
			vec3 detail_n;

			if (use_detail_textures) {
				// Real tiling PBR ground (CC0 AmbientCG set). Pattern-multiply the
				// albedo so the site's true ortho colour is preserved while the
				// texture's fine grain + normal + roughness carry the realism.
				vec2 tuv = wp / max(detail_tex_tile_m, 0.05);
				vec3 talb = texture(detail_albedo_tex, tuv).rgb;
				float tl = max(dot(talb, vec3(0.3333)), 0.05);
				vec3 patt = talb / tl;                       // ~unit-mean grain
				col *= mix(vec3(1.0), patt, k);
				float rr = texture(detail_rough_tex, tuv).r;
				rough = mix(rough, rr, k);
				vec3 nt = texture(detail_normal_tex, tuv).xyz * 2.0 - 1.0;
				nt.xy *= detail_tex_normal_strength;
				detail_n = normalize(world_n + (nt.x * tan_u + nt.y * tan_v));
			} else {
				// Procedural fallback (asset-free): gradient of an fBm height
				// field drives the relief; a finer octave adds crisp micro-grain.
				float scale = 1.0 / max(near_detail_tile_m, 0.05);
				float eps = 0.35 * near_detail_tile_m;
				float h_c = _fbm(wp * scale);
				float h_x = _fbm((wp + vec2(eps, 0.0)) * scale);
				float h_z = _fbm((wp + vec2(0.0, eps)) * scale);
				float f_c = _fbm(wp * scale * 4.0);
				float f_x = _fbm((wp + vec2(eps * 0.25, 0.0)) * scale * 4.0);
				float f_z = _fbm((wp + vec2(0.0, eps * 0.25)) * scale * 4.0);
				vec2 grad = vec2((h_x - h_c) + 0.5 * (f_x - f_c),
								 (h_z - h_c) + 0.5 * (f_z - f_c)) / eps;
				detail_n = normalize(world_n
					- grad.x * tan_u * (near_detail_bump * 8.0)
					- grad.y * tan_v * (near_detail_bump * 8.0));
				float grain = mix(h_c, f_c, 0.5);
				col *= mix(1.0, 0.78 + 0.44 * grain, k * near_detail_albedo);
				rough = mix(rough, clamp(rough * (0.92 + 0.16 * grain), 0.0, 1.0), k);
			}

			world_n = normalize(mix(world_n, detail_n, k));
		}
	}

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
	// Apply the (optionally perturbed) world normal. Far away world_n == the
	// geometric normal, so the distant look is untouched; NORMAL is view-space.
	NORMAL = normalize((VIEW_MATRIX * vec4(world_n, 0.0)).xyz);
}
