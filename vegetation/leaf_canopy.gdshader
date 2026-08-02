// Shell-extruded leaf canopy shader for deciduous trees. Adapted from the grass
// shell technique (vegetation/grass.gdshader): the mesh is a stack of nested
// lumpy ellipsoid "shells" wrapping the crown (see vegetation_card_factory.gd
// _build_leaf_shell_canopy), NOT crossed billboard cards. Each vertex carries
// COLOR.r = shell depth (0 inner core, 1 outer surface) and COLOR.g = normalized
// tree height (for wind). Per fragment, a cell grid over the crown surface stamps
// ONE procedural leaf per cell (a rotated lanceolate mask), randomized per-cell
// and per-instance; a per-shell random gap drops some cells so the OUTER shell's
// holes reveal the INNER shell's leaves — many stacked shells then read as a
// dense volumetric canopy of discrete leaves rather than a blurry billboard puff.
// Opaque cutout (discard) + screen-space dither at distance (same softening as
// foliage.gdshader), the full seasonal response (autumn recolor, leaf-loss
// thinning, spring bud, winter desaturation, snow) driven live by
// VegetationEnvironmentSync, and deciduous-profile wind from VegetationWindDriver.
shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha;

#include "res://vegetation/wind_vertex.gdshaderinc"
#include "res://vegetation/leaf_phenology.gdshaderinc"
#include "res://core/soi/shaders/soi_clip.gdshaderinc"

// 0 = deciduous broadleaf, 1 = conifer needle (grass-style streak mask).
uniform int canopy_profile = 0;

uniform vec3 leaf_color : source_color = vec3(0.16, 0.36, 0.10);
uniform vec3 leaf_shadow : source_color = vec3(0.05, 0.13, 0.04);
uniform vec3 albedo_tint : source_color = vec3(1.0);
uniform vec3 highlight_tint : source_color = vec3(0.42, 0.52, 0.16);

// --- Procedural leaf grid (analogue of the grass fake-blade grid) ---
uniform float cells_per_side : hint_range(4.0, 64.0) = 26.0;
uniform float leaf_size : hint_range(0.3, 1.0) = 0.85;     // leaf fill fraction of a cell
uniform float leaf_aspect : hint_range(1.0, 3.5) = 1.9;    // length / width
uniform float shell_gap : hint_range(0.0, 0.9) = 0.35;     // fraction of empty cells per shell

// --- Alpha cutout + distance dither (mirrors foliage.gdshader) ---
uniform float alpha_dither_min : hint_range(0.0, 1.0) = 0.20;
uniform float alpha_dither_max : hint_range(0.0, 1.0) = 0.50;
uniform float dither_strength : hint_range(0.0, 1.0) = 1.0;
uniform float near_crisp_m : hint_range(0.0, 120.0) = 40.0;
uniform float far_dither_m : hint_range(40.0, 300.0) = 120.0;

// --- Realism knobs (shared names with foliage.gdshader) ---
uniform float roughness_value : hint_range(0.0, 1.0) = 0.95;
uniform vec3 ao_tint : source_color = vec3(0.65, 0.7, 0.55);
uniform float ao_strength : hint_range(0.0, 1.0) = 0.40;
uniform float subsurface_strength : hint_range(0.0, 1.0) = 0.15;
uniform float translucency_strength : hint_range(0.0, 1.0) = 0.25;
uniform float color_variation : hint_range(0.0, 0.25) = 0.14;
uniform float hue_jitter : hint_range(0.0, 0.15) = 0.05;

uniform vec3 haze_color : source_color = vec3(0.07, 0.13, 0.04);
uniform float haze_start : hint_range(0.0, 2000.0) = 200.0;
uniform float haze_end : hint_range(0.0, 2000.0) = 700.0;
uniform float haze_strength : hint_range(0.0, 1.0) = 0.65;

uniform float night_factor : hint_range(0.0, 1.0) = 0.0;
uniform float night_darkness : hint_range(0.0, 1.0) = 0.82;
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);

// --- Seasonal phenology + snow (driven live by VegetationEnvironmentSync) ---
uniform float deciduousness : hint_range(0.0, 1.0) = 1.0;
uniform float autumn : hint_range(0.0, 1.0) = 0.0;
uniform float leaf_coverage : hint_range(0.0, 1.0) = 1.0;
uniform float spring_bud : hint_range(0.0, 1.0) = 0.0;
uniform float winter : hint_range(0.0, 1.0) = 0.0;
uniform float snow_amount : hint_range(0.0, 1.0) = 0.0;
uniform float snow_depth_m = 0.0;
uniform vec3 snow_color : source_color = vec3(0.92, 0.94, 0.98);
uniform vec3 autumn_warm : source_color = vec3(0.96, 0.78, 0.12);
uniform vec3 autumn_orange : source_color = vec3(0.93, 0.45, 0.06);
uniform vec3 autumn_hot : source_color = vec3(0.80, 0.13, 0.04);
uniform vec3 bud_color : source_color = vec3(0.55, 0.78, 0.24);

varying float v_view_dist;
varying vec3 v_world_pos;
varying vec3 v_inst_pos;
varying vec3 v_crown_dir;
varying float v_shell_t;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void vertex() {
	float shell_t = COLOR.r;
	float top_mask = COLOR.g;
	v_shell_t = shell_t;
	// Mesh NORMAL stores the crown-radial unit direction (leaves point outward),
	// which we reuse both for lighting and to lay out the per-cell leaf grid.
	v_crown_dir = normalize(NORMAL);
	vec3 inst_pos = MODEL_MATRIX[3].xyz;
	float vert_phase = dot(VERTEX, vec3(17.3, 31.1, 11.7)) + inst_pos.x * 3.7 + inst_pos.z * 5.1;
	VERTEX = apply_vegetation_wind(VERTEX, inst_pos, top_mask, vert_phase);
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_view_dist = length((VIEW_MATRIX * vec4(world_pos, 1.0)).xyz);
	v_world_pos = world_pos;
	v_inst_pos = inst_pos;
}

void fragment() {
	soi_clip_fragment(v_world_pos);
	// ---- Per-cell procedural leaf over the crown surface ----
	// Spherical parameterisation of the crown-radial direction gives a stable
	// 2D grid that sticks to the canopy surface. A per-instance rotation of the
	// azimuth makes neighbouring trees carry different leaf patterns.
	vec3 dir = normalize(v_crown_dir);
	float inst_seed = hash21(floor(v_inst_pos.xz * 0.5) + 0.5);
	float az = atan(dir.z, dir.x) + inst_seed * 6.2831;
	float incl = acos(clamp(dir.y, -1.0, 1.0));
	float u = fract(az / 6.2831);
	float v = clamp(incl / 3.14159265, 0.0, 1.0);

	float ucells = max(floor(cells_per_side * 2.0), 2.0);
	float vcells = max(floor(cells_per_side), 2.0);
	vec2 cell_f = vec2(u * ucells, v * vcells);
	// Per-shell phase offset so leaves on stacked shells interleave (parallax).
	cell_f += vec2(v_shell_t * 3.17, v_shell_t * 2.11);
	vec2 cell = floor(cell_f);
	vec2 local = fract(cell_f) - 0.5;

	vec2 seed2 = vec2(inst_seed * 19.3, inst_seed * 7.7);
	float ang = hash21(cell + seed2 + 4.1) * 6.2831;
	float ca = cos(ang);
	float sa = sin(ang);
	vec2 p = vec2(local.x * ca - local.y * sa, local.x * sa + local.y * ca);
	float mask;
	// Dormant leaves curl a little; the canopy thins mostly by LOSING leaves
	// (below), which is what the card + impostor tiers do — this used to shrink
	// every leaf to nothing instead, so a tree changed how it went bare as it
	// crossed a ring boundary.
	float size_mul = veg_leaf_size_mul(leaf_coverage, deciduousness);
	float eff_size = max(leaf_size * size_mul, 0.001);
	
	if (canopy_profile > 0) {
		// Conifer needles: thin elongated streaks (same technique as grass blades).
		float lean = hash21(cell + seed2 + 9.3) * 0.35;
		vec2 shifted = local - vec2(cos(ang), sin(ang)) * lean * 0.25;
		vec2 blade_local = vec2(shifted.x * ca - shifted.y * sa, shifted.x * sa + shifted.y * ca);
		float radius = max(eff_size * 0.5 / max(leaf_aspect, 1.0), 0.015);
		mask = (1.0 - smoothstep(radius * 0.55, radius, abs(blade_local.x)));
		mask *= 1.0 - smoothstep(0.38, 0.52, abs(blade_local.y));
	} else {
		float half_w = max(0.5 * eff_size / leaf_aspect, 0.02);
		float half_l = max(0.5 * eff_size, 0.04);
		float ex = p.x / half_w;
		float ey = p.y / half_l;
		float leaf_angle = atan(ex, ey);
		// Lobed edge for realistic broadleaf look (e.g. oak/maple)
		float lobes = 1.0 + 0.25 * sin(leaf_angle * 5.0) * sin(leaf_angle * 3.0);
		// Lanceolate taper: leaf narrows toward its tip (|ey| -> 1).
		float taper = 1.0 - smoothstep(0.0, 1.0, abs(ey)) * 0.65;
		float d = (ex * ex) + (ey * ey);
		mask = 1.0 - smoothstep(0.70, 1.0, d / max(taper * taper * lobes * lobes, 0.05));
	}
	// Per-shell empty cells (the parallax gaps that make stacked shells read as
	// a volume) and seasonal leaf loss share one hash: leaf fall simply widens
	// the gap threshold over the cells that survived it, so the canopy thins by
	// losing WHOLE leaves and reaches bare exactly at leaf_coverage 0.
	float gap = hash21(cell + vec2(v_shell_t * 37.0, v_shell_t * 23.0) + seed2);
	float leaf_loss = veg_leaf_loss(leaf_coverage, deciduousness);
	if (gap < shell_gap + leaf_loss * (1.0 - shell_gap)) {
		mask = 0.0;
	}

	ALPHA = mask;

	// ---- Distance dither (mirror foliage.gdshader edge softening) ----
	float dist_t = clamp((v_view_dist - haze_start) / max(haze_end - haze_start, 1.0), 0.0, 1.0);
	float dmin = mix(alpha_dither_min, alpha_dither_min * 0.4, dist_t);
	float dmax = mix(alpha_dither_max, alpha_dither_max * 0.5, dist_t);
	vec2 pxc = floor(FRAGCOORD.xy);
	float dith = fract(sin(dot(pxc, vec2(12.9898, 78.233))) * 43758.5453);
	float threshold = mix(dmin, dmax, dith);
	bool use_scissor = near_crisp_m > 0.0 && v_view_dist < near_crisp_m;
	float crisp_blend = 1.0 - smoothstep(near_crisp_m, far_dither_m, v_view_dist);
	if (crisp_blend > 0.5) {
		use_scissor = true;
	}
	float eff_thresh = mix(threshold, 0.35, 1.0 - dither_strength);
	if (use_scissor) {
		if (mask < 0.35) {
			discard;
		}
	} else if (mask < eff_thresh) {
		discard;
	}

	// ---- Lighting normal (double-sided) ----
	float face_factor = 1.0;
	vec3 nrm = NORMAL;
	if (!FRONT_FACING) {
		nrm = -NORMAL;
		face_factor = 0.55;
	}
	NORMAL = nrm;

	// ---- Base leaf albedo ----
	float canopy_top = clamp(dir.y * 0.5 + 0.5, 0.0, 1.0);
	vec3 albedo = mix(leaf_shadow, leaf_color, mix(0.35, 1.0, v_shell_t)) * albedo_tint * face_factor;
	if (canopy_profile == 0) {
		// Midrib / leaf-center brightening for a bit of blade shape.
		float half_w = max(0.5 * leaf_size / leaf_aspect, 0.02);
		vec2 p = vec2(local.x * ca - local.y * sa, local.x * sa + local.y * ca);
		float ex = p.x / half_w;
		float center = 1.0 - smoothstep(0.0, 0.5, abs(ex));
		albedo += highlight_tint * center * 0.12 * canopy_top;
	}

	if (color_variation > 0.0) {
		vec2 vcell = floor(v_world_pos.xz / 2.5);
		float cv = fract(sin(dot(vcell, vec2(17.3, 91.7))) * 43758.5453) * 2.0 - 1.0;
		albedo *= 1.0 + cv * color_variation;
		float sat = 1.0 + cv * color_variation * 0.35;
		float luma0 = dot(albedo, vec3(0.299, 0.587, 0.114));
		albedo = mix(vec3(luma0), albedo, sat);
	}
	if (hue_jitter > 0.0) {
		vec2 hcell = floor(v_world_pos.xz / 3.0);
		float hj = fract(sin(dot(hcell, vec2(41.0, 289.0))) * 43758.5453) * 2.0 - 1.0;
		albedo *= 1.0 + hj * hue_jitter;
	}

	// Seasonal response — shared with the card + impostor tiers via
	// leaf_phenology.gdshaderinc. Hue variety is keyed per tree (the same
	// instance seed the leaf grid uses), so a crown turns as one.
	float svar = veg_phenology_hash(vec2(inst_seed * 73.1, inst_seed * 11.7));
	albedo = veg_apply_bud(albedo, spring_bud * deciduousness, bud_color);
	albedo = veg_apply_autumn(albedo, autumn * deciduousness, svar,
		autumn_warm, autumn_orange, autumn_hot);
	albedo = veg_apply_winter(albedo, winter);

	// AO: inner shells sit deeper in the crown volume and read darker.
	albedo = mix(albedo, albedo * ao_tint, (1.0 - v_shell_t) * ao_strength);

	vec3 lit_dir = normalize(sun_direction);
	float sun_up = max(0.0, dot(lit_dir, NORMAL)) * (1.0 - night_factor);
	albedo += highlight_tint * sun_up * subsurface_strength * canopy_top;
	if (translucency_strength > 0.001) {
		vec3 view_dir = normalize(CAMERA_POSITION_WORLD - v_world_pos);
		float back = max(0.0, dot(-lit_dir, view_dir));
		albedo += highlight_tint * back * translucency_strength * canopy_top * (1.0 - night_factor);
	}

	// Snow settling on the canopy: favours upward-facing normals + the crown top.
	float snow_rough = roughness_value;
	if (snow_amount > 0.001 || snow_depth_m > 0.001) {
		float depth_t = clamp(snow_depth_m / 1.5, 0.0, 1.0);
		float up = clamp(NORMAL.y * 0.5 + 0.5, 0.0, 1.0);
		float hold = mix(0.6, 1.0, 1.0 - deciduousness);
		float snow_mask = clamp((snow_amount * 0.35 + depth_t * 0.8) * mix(0.3, 1.0, canopy_top) * (0.35 + 0.65 * up) * hold, 0.0, 1.0);
		albedo = mix(albedo, snow_color, snow_mask);
		snow_rough = mix(roughness_value, 0.6, snow_mask);
	}

	albedo *= 1.0 - night_factor * night_darkness;

	float haze_amount = dist_t * haze_strength * (1.0 - night_factor);
	ALBEDO = albedo * (1.0 - haze_amount);
	EMISSION = haze_color * haze_amount;
	ROUGHNESS = snow_rough;
	METALLIC = 0.0;
}
