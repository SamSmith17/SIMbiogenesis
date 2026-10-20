// Foliage card shader for MultiMeshInstance3D-based vegetation scatter.
shader_type spatial;
// diffuse_lambert_wrap: light wraps round a leaf card the way it scatters
// through a real crown, instead of a hard terminator that leaves half of every
// card in flat ambient.
// ONE opaque pass (2026-10-18). This shipped as depth_prepass_alpha — a depth
// pre-pass AND an alpha pass, each resolving every leaf edge under MSAA — and
// on the user's own site the canopy was 24 of 31 GPU ms at half render scale
// (tools/bench/gpu_toggle_bench.gd). Writing ALPHA_SCISSOR_THRESHOLD beside
// ALPHA keeps the material in the opaque pass: the cutout is still decided by
// the discard rules below, a surviving texel is simply solid, and the measured
// cost fell by 9 ms at 8x MSAA with no visible change in the bench's PNGs.
render_mode cull_disabled, diffuse_lambert_wrap;

#include "res://vegetation/veg_lighting.gdshaderinc"
#include "res://vegetation/wind_vertex.gdshaderinc"
#include "res://vegetation/leaf_phenology.gdshaderinc"
#include "res://vegetation/veg_growth.gdshaderinc"

#include "res://core/soi/shaders/soi_clip.gdshaderinc"

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D drape_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform bool use_drape = false;
uniform float drape_extent_m = 30000.0;
uniform float drape_match_strength : hint_range(0.0, 1.0) = 0.0;
uniform vec3  albedo_tint : source_color = vec3(1.0);
uniform vec3  highlight_tint : source_color = vec3(1.0);
uniform float alpha_dither_min : hint_range(0.0, 1.0) = 0.20;
uniform float alpha_dither_max : hint_range(0.0, 1.0) = 0.50;
uniform float dither_strength : hint_range(0.0, 1.0) = 1.0;
uniform float trunk_uv_cutoff : hint_range(0.0, 1.0) = 0.0;
uniform float near_crisp_m : hint_range(0.0, 120.0) = 40.0;
uniform float far_dither_m : hint_range(40.0, 300.0) = 120.0;
uniform float roughness_value  : hint_range(0.0, 1.0) = 0.95;
uniform vec3  ao_tint : source_color = vec3(0.65, 0.7, 0.55);
uniform float ao_strength : hint_range(0.0, 1.0) = 0.35;
uniform vec3  haze_color    : source_color           = vec3(0.07, 0.13, 0.04);
uniform float haze_start    : hint_range(0.0, 2000.0) = 200.0;
uniform float haze_end      : hint_range(0.0, 2000.0) = 700.0;
uniform float haze_strength : hint_range(0.0, 1.0)   = 0.65;
uniform float lean_amount : hint_range(0.0, 1.0) = 0.30;
uniform float subsurface_strength : hint_range(0.0, 1.0) = 0.15;
uniform float translucency_strength : hint_range(0.0, 1.0) = 0.25;
uniform float canopy_roundness : hint_range(0.0, 1.0) = 0.40;
uniform float color_variation : hint_range(0.0, 0.25) = 0.12;
uniform float hue_jitter : hint_range(0.0, 0.15) = 0.0;
// Soft procedural tufts on billboard whorls (pine near LOD). Round blobs, not needles.
uniform float fur_strength : hint_range(0.0, 1.0) = 0.0;
uniform float fur_cells : hint_range(4.0, 48.0) = 20.0;
uniform float fur_tuft_size : hint_range(0.15, 1.0) = 0.58;
uniform float fur_gap : hint_range(0.0, 0.85) = 0.24;
// Near-invisible billboard layer under leaf shells (deciduous hybrid shadow proxy).
uniform float color_fade : hint_range(0.0, 1.0) = 1.0;
// Per-instance whorl spin/offset for pines (breaks vertical repeat on shared mesh).
uniform float whorl_variation_strength : hint_range(0.0, 1.0) = 0.0;
uniform float whorl_band_h : hint_range(0.2, 2.0) = 0.62;
// Pine: tighten whorl alpha toward the top edge of each card (cone silhouette).
uniform float cone_sharpness : hint_range(0.0, 1.0) = 0.0;
uniform float seasonal_strength : hint_range(0.0, 1.0) = 0.0;
uniform vec3 seasonal_tint : source_color = vec3(1.0, 0.92, 0.75);
uniform float night_factor : hint_range(0.0, 1.0) = 0.0;
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
// How dark foliage goes at full night. Multiplies ALBEDO by (1 - night*this) so
// the moon's directional light can't make leaves glow; dim ambient still tints
// them as moonlit. 0 = no change (previous behaviour).
uniform float night_darkness : hint_range(0.0, 1.0) = 0.65;
// How much SUN a card keeps where the shadow map says it is shadowed. A crown
// of crossed alpha cards is almost entirely in its own shadow, so by the
// shadow map a pine or a photocard is lit by ambient alone — and with a low
// world ambient (0.05 is a real player setting) it printed near-black beside
// sunlit leaf shells. Real foliage transmits and scatters light through the
// crown (a shaded needle is ~30-50 % of a sunlit one, not ~0), so the sun's
// shadow is floored here. Directional (sun/moon) only — local lights keep
// their own attenuation.
uniform float shadow_floor : hint_range(0.0, 1.0) = 0.45;
// --- Seasonal phenology + snow (driven live by VegetationEnvironmentSync) ---
// deciduousness: 0 = evergreen conifer, 1 = deciduous broadleaf (per-material).
uniform float deciduousness : hint_range(0.0, 1.0) = 1.0;
uniform float autumn : hint_range(0.0, 1.0) = 0.0;        // warm-colour blend
uniform float leaf_coverage : hint_range(0.0, 1.0) = 1.0; // 1 full canopy, 0 bare
uniform float spring_bud : hint_range(0.0, 1.0) = 0.0;    // fresh growth tint
uniform float winter : hint_range(0.0, 1.0) = 0.0;        // dormancy desaturation
uniform float snow_amount : hint_range(0.0, 1.0) = 0.0;   // ground snow cover
uniform float snow_depth_m = 0.0;
uniform vec3 snow_color : source_color = vec3(0.92, 0.94, 0.98);
uniform vec3 autumn_warm : source_color = vec3(0.96, 0.78, 0.12);   // yellow
uniform vec3 autumn_orange : source_color = vec3(0.93, 0.45, 0.06); // orange
uniform vec3 autumn_hot : source_color = vec3(0.80, 0.13, 0.04);    // red
uniform vec3 bud_color : source_color = vec3(0.55, 0.78, 0.24);
// Broadleaf leaf SPRAYS (VegBroadleafBuilder): the vertex COLOR carries what a
// card's UV.y used to stand in for — r = depth into the crown (0 = outer
// leaves), g = height fraction of the tree (wind), b = a per-spray seed (leaf
// fall). Off for every card / conifer material, so they are unchanged.
uniform bool spray_mode = false;

varying float v_view_dist;
varying vec3 v_world_pos;
varying vec3 v_inst_pos;
varying float v_growth_leaf;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float pine_fur_tuft(vec2 uv, vec3 inst_pos) {
	float ucells = max(fur_cells, 4.0);
	vec2 cell_f = uv * ucells;
	vec2 cell = floor(cell_f);
	vec2 local = fract(cell_f) - 0.5;
	float inst_seed = hash21(floor(inst_pos.xz * 0.5) + 0.5);
	vec2 seed2 = vec2(inst_seed * 19.3, inst_seed * 7.7);
	float ang = hash21(cell + seed2 + 4.1) * 6.2831;
	float ca = cos(ang);
	float sa = sin(ang);
	vec2 p = vec2(local.x * ca - local.y * sa, local.x * sa + local.y * ca);
	float radius = max(fur_tuft_size * 0.42, 0.06);
	float d = length(p / radius);
	float tuft = 1.0 - smoothstep(0.50, 1.0, d);
	float gap = hash21(cell + seed2 + 9.3);
	if (gap < fur_gap) {
		tuft = 0.0;
	}
	return tuft;
}

void vertex() {
	float top_mask = spray_mode ? COLOR.g : 1.0 - UV.y;
	vec3 inst_pos = MODEL_MATRIX[3].xyz;
	// Growth first, in model space (height + crown width from the plant's age).
	float g_gen;
	vec4 g_st = veg_growth_state(INSTANCE_CUSTOM, g_gen);
	v_growth_leaf = g_st.w;
	VERTEX = veg_growth_apply(VERTEX, g_st.x, g_st.y,
		veg_growth_generation(g_gen, INSTANCE_CUSTOM.w));
	if (whorl_variation_strength > 0.001 && VERTEX.y > 0.15) {
		float inst_seed = hash21(inst_pos.xz * 0.37);
		float tier = floor(VERTEX.y / max(whorl_band_h, 0.05));
		float tier_rot = (hash21(vec2(tier, inst_seed * 41.0)) - 0.5)
			* 3.14159 * whorl_variation_strength * 0.55;
		vec2 xz = VERTEX.xz;
		float c = cos(tier_rot);
		float s = sin(tier_rot);
		VERTEX.x = xz.x * c - xz.y * s;
		VERTEX.z = xz.x * s + xz.y * c;
	}
	float vert_phase = dot(VERTEX, vec3(17.3, 31.1, 11.7));
	VERTEX = apply_vegetation_wind(VERTEX, inst_pos, top_mask, vert_phase);

	vec3 to_cam_xz = CAMERA_POSITION_WORLD - inst_pos;
	to_cam_xz.y = 0.0;
	float cam_dist_xz = length(to_cam_xz);
	float lean_blend = smoothstep(30.0, 100.0, cam_dist_xz);
	vec3 lean_dir = cam_dist_xz > 0.5 ? to_cam_xz / cam_dist_xz : vec3(0.0, 0.0, 1.0);

	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_pos += lean_dir * (top_mask * top_mask * lean_amount * lean_blend);

	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos, 1.0);
	v_view_dist = length((VIEW_MATRIX * vec4(world_pos, 1.0)).xyz);
	v_world_pos = world_pos;
	v_inst_pos = inst_pos;
}

// Godot's diffuse_lambert_wrap, re-stated so the sun's shadow can be floored
// (see shadow_floor). Specular is left at 0 on purpose: a leaf card is matte.
void light() {
	float ndl = dot(NORMAL, LIGHT);
	float wrap = 1.0 + ROUGHNESS;
	float diffuse = max(0.0, (ndl + ROUGHNESS) / (wrap * wrap));
	float att = LIGHT_IS_DIRECTIONAL ? mix(shadow_floor, 1.0, ATTENUATION) : ATTENUATION;
	DIFFUSE_LIGHT += LIGHT_COLOR * att * diffuse / PI;
	// Transmission (the fragment's BACKLIGHT, lit from behind the card).
	DIFFUSE_LIGHT += LIGHT_COLOR * att * BACKLIGHT * max(0.0, -ndl) / PI;
}

void fragment() {
	soi_clip_fragment(v_world_pos);
	vec4 tex = texture(albedo_tex, UV);
	float alpha = tex.a;
	if (cone_sharpness > 0.001) {
		// Emphasize the upper arc of each whorl puff so stacked tiers read as a cone.
		float top_arc = smoothstep(0.08, 0.72, 1.0 - UV.y);
		float horiz = 1.0 - abs(UV.x - 0.5) * 2.0;
		alpha *= mix(1.0, top_arc * mix(0.55, 1.0, horiz), cone_sharpness);
	}
	float fur_tuft = 0.0;
	if (fur_strength > 0.001) {
		fur_tuft = pine_fur_tuft(UV, v_inst_pos);
		// Internal texture only — do not blob past the billboard puff silhouette.
		float inner = tex.a * (0.88 + 0.12 * fur_tuft);
		alpha = mix(tex.a, inner, fur_strength);
	}
	ALPHA = alpha;
	ALPHA_SCISSOR_THRESHOLD = 0.02;  // opaque pass; the discards below are the cutout

	float dist_t = clamp((v_view_dist - haze_start) / max(haze_end - haze_start, 1.0), 0.0, 1.0);
	float dmin = mix(alpha_dither_min, alpha_dither_min * 0.4, dist_t);
	float dmax = mix(alpha_dither_max, alpha_dither_max * 0.5, dist_t);

	vec2  px      = floor(FRAGCOORD.xy);
	float dither  = fract(sin(dot(px, vec2(12.9898, 78.233))) * 43758.5453);
	float threshold = mix(dmin, dmax, dither);

	bool use_scissor = (trunk_uv_cutoff > 0.0 && UV.y > trunk_uv_cutoff)
		|| (near_crisp_m > 0.0 && v_view_dist < near_crisp_m);
	float crisp_blend = 1.0 - smoothstep(near_crisp_m, far_dither_m, v_view_dist);
	if (crisp_blend > 0.5) {
		use_scissor = true;
	}

	float eff_thresh = mix(threshold, 0.35, 1.0 - dither_strength);
	if (use_scissor) {
		if (alpha < 0.35) {
			discard;
		}
	} else if (alpha < eff_thresh) {
		discard;
	}

	// Deciduous leaf loss: thin the card by discarding clumps of its foliage as
	// leaf_coverage drops in late autumn / winter. The key is the card's own UV
	// grid plus a per-instance seed, so a gap stays put on the tree — this used
	// to reuse `dither` (screen space) and crawled across the canopy whenever
	// the camera moved.
	float leaf_inst_seed = hash21(floor(v_inst_pos.xz * 0.5) + 0.5);
	vec2 leaf_key = floor(UV * 13.0) + vec2(leaf_inst_seed * 19.3, leaf_inst_seed * 7.7);
	if (spray_mode) {
		// Per spray, and per leaf-sized cell of it: a crown thins spray by
		// spray, not the same leaf of every spray at once.
		leaf_key = floor(UV * vec2(7.0, 3.0)) + vec2(COLOR.b * 211.0 + leaf_inst_seed * 19.3,
			COLOR.b * 57.0 + leaf_inst_seed * 7.7);
	}
	if (veg_leaf_fallen(leaf_key, leaf_coverage, deciduousness)) {
		discard;
	}
	// A declining tree thins to a bare snag whatever the season, evergreen or not.
	if (veg_growth_leaf_gone(leaf_key, v_growth_leaf)) {
		discard;
	}

	// (No manual back-face flip — see veg_lighting.gdshaderinc.)
	float face_factor = FRONT_FACING ? 1.0 : VEG_BACK_FACE;
	vec3 nrm = NORMAL;
	if (canopy_roundness > 0.001) {
		vec3 to_crown = v_world_pos - v_inst_pos;
		to_crown.y = max(to_crown.y, 0.0);
		if (dot(to_crown, to_crown) > 1e-4) {
			// The crown normal is WORLD space; NORMAL is view space.
			vec3 round_n = normalize((VIEW_MATRIX * vec4(normalize(to_crown + vec3(0.0, 0.35, 0.0)), 0.0)).xyz);
			float crown_t = (spray_mode ? 1.0 - COLOR.r : 1.0 - UV.y) * canopy_roundness;
			nrm = normalize(mix(nrm, round_n, crown_t));
		}
	}
	NORMAL = nrm;
	vec3 wn = veg_world_normal(nrm, INV_VIEW_MATRIX);

	vec3 albedo = veg_saturate(tex.rgb * albedo_tint, veg_saturation) * face_factor;
	if (fur_strength > 0.001) {
		albedo *= 1.0 + (fur_tuft - 0.45) * 0.14 * fur_strength;
		albedo += highlight_tint * fur_tuft * 0.06 * fur_strength * (1.0 - UV.y);
	}
	if (hue_jitter > 0.0) {
		vec2 cell = floor(v_world_pos.xz / 3.0);
		float hj = fract(sin(dot(cell, vec2(41.0, 289.0))) * 43758.5453) * 2.0 - 1.0;
		albedo *= 1.0 + hj * hue_jitter;
	}
	if (color_variation > 0.0) {
		vec2 vcell = floor(v_world_pos.xz / 2.5);
		float cv = fract(sin(dot(vcell, vec2(17.3, 91.7))) * 43758.5453) * 2.0 - 1.0;
		albedo *= 1.0 + cv * color_variation;
		float sat = 1.0 + cv * color_variation * 0.35;
		float luma = dot(albedo, vec3(0.299, 0.587, 0.114));
		albedo = mix(vec3(luma), albedo, sat);
	}
	if (seasonal_strength > 0.0) {
		albedo = mix(albedo, albedo * seasonal_tint, seasonal_strength);
	}

	// Seasonal response — shared with the leaf-shell and impostor tiers via
	// leaf_phenology.gdshaderinc, so a tree looks the same season on both sides
	// of a ring boundary. Hue variety is keyed PER TREE (the instance seed), not
	// per world cell, so a single crown turns as one.
	float svar = veg_phenology_hash(vec2(leaf_inst_seed * 73.1, leaf_inst_seed * 11.7));
	albedo = veg_apply_bud(albedo, spring_bud * deciduousness, bud_color);
	albedo = veg_apply_autumn(albedo, autumn * deciduousness, svar,
		autumn_warm, autumn_orange, autumn_hot);
	albedo = veg_apply_winter(albedo, winter);

	if (use_drape && drape_match_strength > 0.0 && drape_extent_m > 0.0) {
		vec2 duv = (v_world_pos.xz + drape_extent_m * 0.5) / drape_extent_m;
		if (duv.x >= 0.0 && duv.x <= 1.0 && duv.y >= 0.0 && duv.y <= 1.0) {
			vec3 drape = texture(drape_tex, duv).rgb;
			albedo = mix(albedo, albedo * drape / max(drape.g, 0.05), drape_match_strength);
		}
	}

	// Card: darker toward its foot. Spray: darker deep inside the crown.
	float bottom_t = spray_mode ? COLOR.r : UV.y;
	albedo = mix(albedo, albedo * ao_tint, bottom_t * ao_strength);

	vec3 lit_dir = normalize(sun_direction);
	float sun_up = max(0.0, dot(lit_dir, wn)) * (1.0 - night_factor);
	float top_mask = spray_mode ? 1.0 - COLOR.r : 1.0 - UV.y;
	albedo += highlight_tint * sun_up * subsurface_strength * top_mask;
	if (translucency_strength > 0.001) {
		// Real transmission: BACKLIGHT is lit by the sun from BEHIND the leaf.
		// (Added into ALBEDO it was then multiplied by N·L, which is ~0 exactly
		// where the glow belongs, and only desaturated the front toward yellow.)
		BACKLIGHT = highlight_tint * translucency_strength * top_mask * (1.0 - night_factor);
	}

	// Snow settling on the canopy: favours upward-facing normals and the top of
	// the card. Evergreens (low deciduousness) hold more snow than bare branches.
	float snow_rough = roughness_value;
	if (snow_amount > 0.001 || snow_depth_m > 0.001) {
		float depth_t = clamp(snow_depth_m / 1.5, 0.0, 1.0);
		float up = clamp(wn.y * 0.5 + 0.5, 0.0, 1.0);
		float top = spray_mode ? 1.0 - COLOR.r : 1.0 - UV.y;
		float hold = mix(0.6, 1.0, 1.0 - deciduousness);
		float snow_mask = clamp((snow_amount * 0.35 + depth_t * 0.8) * mix(0.25, 1.0, top) * (0.35 + 0.65 * up) * hold, 0.0, 1.0);
		albedo = mix(albedo, snow_color, snow_mask);
		snow_rough = mix(roughness_value, 0.6, snow_mask);
	}

	// Darken at night so the moon's directional light can't make leaves glow.
	albedo *= 1.0 - night_factor * night_darkness;

	float haze_amount = dist_t * haze_strength * (1.0 - night_factor) * veg_haze_mul;
	ALBEDO    = albedo * (1.0 - haze_amount) * color_fade;
	EMISSION  = (haze_color * haze_amount
			+ albedo * (1.0 - haze_amount) * veg_fill_amount() * (1.0 - night_factor)) * color_fade;
	ALBEDO    = veg_hl_albedo(ALBEDO);
	EMISSION += veg_hl_emission();

	ROUGHNESS = snow_rough;
	METALLIC  = 0.0;
	// A leaf is matte: the default 0.5 put a grey sheen on every grazing card.
	SPECULAR  = 0.25;
}
