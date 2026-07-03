// Shell-extruded turf shader. The mesh is a stack of flat horizontal "shells"
// (see vegetation/grass_builder.gd _build_shell_mesh), not individual blade
// cards. Each shell's vertex COLOR.r carries its normalized height (0 ground,
// 1 tip). Per fragment, a cell grid simulates one fake "blade" per cell: its
// height, lean, and width are randomized per-cell (and per-instance via a
// world-space seed), and it fades out above its own randomized max height —
// so many shells stacked together read as a dense sweep of individual blades
// from up close, without ever instancing per-blade geometry. Opaque cutout
// (ALPHA + discard), same as the old per-blade version, so shadow casting stays
// off and there's no sort-order blending cost.
shader_type spatial;
render_mode cull_disabled;

#include "res://vegetation/wind_vertex.gdshaderinc"

uniform vec3 root_color : source_color = vec3(0.10, 0.32, 0.08);
uniform vec3 tip_color : source_color = vec3(0.14, 0.42, 0.12);
uniform vec3 highlight_color : source_color = vec3(0.28, 0.58, 0.18);
uniform vec3 albedo_tint : source_color = vec3(1.0);
uniform sampler2D drape_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform bool use_drape = false;
uniform float drape_extent_m = 30000.0;
uniform float drape_match_strength : hint_range(0.0, 1.0) = 0.35;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.92;
uniform float subsurface_strength : hint_range(0.0, 1.0) = 0.45;
uniform float near_full_m : hint_range(0.0, 80.0) = 35.0;
uniform float mid_fade_m : hint_range(20.0, 200.0) = 90.0;
uniform float far_patch_m : hint_range(80.0, 400.0) = 280.0;
uniform float patch_strength : hint_range(0.0, 1.0) = 0.85;
uniform float night_factor : hint_range(0.0, 1.0) = 0.0;
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform float hue_jitter : hint_range(0.0, 0.15) = 0.04;
// How dark the turf goes at full night. Multiplies ALBEDO by (1 - night*this)
// so the moon's directional light can't make grass "light up" after dark; the
// dim bluish ambient still reads it as moonlit turf. 0 = no change.
uniform float night_darkness : hint_range(0.0, 1.0) = 0.82;
// Seasonal height scale (driven by VegetationEnvironmentSync from SeasonModel):
// 1 = full seasonal height, 0 = dormant. Grass appears to grow in over spring/
// summer and lay down in autumn/winter. growth_floor keeps a short dormant mat.
uniform float growth : hint_range(0.0, 1.0) = 1.0;
uniform float growth_floor : hint_range(0.0, 1.0) = 0.30;
// --- Shell "fake blade" density (see grass_builder.gd) ---
uniform float cells_per_side : hint_range(2.0, 32.0) = 6.0;
uniform float height_variation : hint_range(0.0, 1.0) = 0.35;
uniform float blade_thickness : hint_range(0.05, 1.0) = 0.5;
uniform float blade_lean : hint_range(0.0, 0.5) = 0.2;
// --- Seasonal dormancy + snow (driven live by VegetationEnvironmentSync) ---
uniform float autumn : hint_range(0.0, 1.0) = 0.0;
uniform float winter : hint_range(0.0, 1.0) = 0.0;
uniform float snow_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec3 dry_color : source_color = vec3(0.52, 0.44, 0.18);   // dormant tan/gold
uniform vec3 snow_color : source_color = vec3(0.92, 0.94, 0.98);

varying float v_view_dist;
varying float v_height_t;
varying vec3 v_world_pos;
varying vec2 v_inst_seed;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void vertex() {
	float top_mask = COLOR.r;
	v_height_t = top_mask;
	// Seasonal growth: compress the shell stack toward the ground when dormant,
	// extend to full height in summer. Normalized height (COLOR.r) is untouched,
	// so blade masking + wind still key off the full 0..1 range.
	VERTEX.y *= mix(growth_floor, 1.0, growth);
	vec3 inst_pos = MODEL_MATRIX[3].xyz;
	v_inst_seed = inst_pos.xz;
	float vert_phase = dot(VERTEX, vec3(17.3, 31.1, 11.7)) + inst_pos.x * 3.7 + inst_pos.z * 5.1;
	VERTEX = apply_vegetation_wind(VERTEX, inst_pos, top_mask, vert_phase);
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world_pos, 1.0);
	v_view_dist = length((VIEW_MATRIX * vec4(world_pos, 1.0)).xyz);
	v_world_pos = world_pos;
}

void fragment() {
	float dist_fade = 1.0 - smoothstep(mid_fade_m, far_patch_m, v_view_dist);
	float patch_blend = smoothstep(mid_fade_m, far_patch_m, v_view_dist) * patch_strength;
	float blade_fade = smoothstep(far_patch_m * 0.92, far_patch_m, v_view_dist);

	// ---- Per-cell fake-blade mask (this shell's slice through the volume) ----
	// Each cell simulates one blade as a thin, elongated streak (not a round
	// dot): its local space is rotated by a per-cell random angle so the
	// streak runs in its own direction, then only the across-blade axis is
	// thresholded — the along-blade axis stays open (softened near the cell
	// edge) so the streak reads as a line/blade rather than a stacked circle.
	vec2 cell_f = UV * cells_per_side + v_inst_seed * 0.913;
	vec2 cell = floor(cell_f);
	vec2 cell_local = fract(cell_f) - 0.5;
	float cell_h = hash21(cell);
	float cell_angle = hash21(cell + 11.7) * 6.2831;

	float cell_max_h = mix(1.0 - height_variation, 1.0, cell_h);
	float height_ok = 1.0 - smoothstep(cell_max_h - 0.02, cell_max_h, v_height_t);

	vec2 lean_dir = vec2(sin(cell_angle), cos(cell_angle));
	vec2 shifted = cell_local - lean_dir * blade_lean * v_height_t;
	float ca = cos(cell_angle);
	float sa = sin(cell_angle);
	// blade_local.x = across the blade (narrow), .y = along the blade (long).
	vec2 blade_local = vec2(shifted.x * ca + shifted.y * sa, -shifted.x * sa + shifted.y * ca);
	float radius = max(blade_thickness * 0.5, 0.02);
	float blade_mask = (1.0 - smoothstep(radius * 0.6, radius, abs(blade_local.x))) * height_ok;
	blade_mask *= 1.0 - smoothstep(0.40, 0.5, abs(blade_local.y));

	// Blend smoothly into a solid patch as distance increases — holes between
	// fake blades fill in exactly where the old per-blade mesh used to give
	// way to a flat ground-tinted quad, so there's no pop at the LOD seam.
	float alpha = mix(blade_mask, 1.0, clamp(patch_blend + blade_fade, 0.0, 1.0));
	if (alpha < 0.04) {
		discard;
	}

	// Cheap fake normal: bends outward from each blade's local center so the
	// sun highlight rounds across the fake blade instead of being perfectly flat.
	vec3 fake_normal = normalize(vec3(shifted.x * 1.6, 1.0, shifted.y * 1.6));

	vec3 base = mix(root_color, tip_color, v_height_t);
	base = mix(base, highlight_color, smoothstep(0.55, 1.0, v_height_t) * 0.35);
	// Cheap AO proxy: lower shells sit inside the "fur volume" and read darker,
	// selling the density of the swept volume without extra geometry.
	base *= mix(0.55, 1.0, v_height_t);
	base *= albedo_tint;

	if (hue_jitter > 0.0) {
		float hj = hash21(cell + v_inst_seed * 0.07) * 2.0 - 1.0;
		base *= 1.0 + hj * hue_jitter;
	}

	if (use_drape && drape_match_strength > 0.0 && drape_extent_m > 0.0) {
		vec2 duv = (v_world_pos.xz + drape_extent_m * 0.5) / drape_extent_m;
		if (duv.x >= 0.0 && duv.x <= 1.0 && duv.y >= 0.0 && duv.y <= 1.0) {
			vec3 drape = texture(drape_tex, duv).rgb;
			base = mix(base, base * drape / max(drape.g, 0.05), drape_match_strength * 0.55);
		}
	}

	vec3 lit_dir = normalize(sun_direction);
	float sun_up = max(0.0, dot(lit_dir, fake_normal)) * (1.0 - night_factor);
	base += highlight_color * sun_up * subsurface_strength * v_height_t;

	// Far distance: flatten to a ground-tinted patch (no alpha pop).
	vec3 patch_col = mix(root_color, tip_color, 0.35) * albedo_tint;
	if (use_drape && drape_extent_m > 0.0) {
		vec2 duv2 = (v_world_pos.xz + drape_extent_m * 0.5) / drape_extent_m;
		if (duv2.x >= 0.0 && duv2.x <= 1.0 && duv2.y >= 0.0 && duv2.y <= 1.0) {
			vec3 drape2 = texture(drape_tex, duv2).rgb;
			patch_col = mix(patch_col, patch_col * drape2 / max(drape2.g, 0.05), 0.65);
		}
	}
	vec3 albedo = mix(base * dist_fade + patch_col * patch_blend, patch_col, blade_fade);

	// Seasonal dormancy: grass cures to gold in autumn and browns off in winter.
	float dryness = clamp(max(winter, autumn * 0.5), 0.0, 1.0);
	albedo = mix(albedo, dry_color, dryness * 0.7);

	// Snow burial: lying snow covers low turf; taller blades poke through.
	float grass_rough = roughness_value;
	if (snow_amount > 0.001) {
		float bury = clamp(snow_amount * (1.0 - v_height_t * 0.5), 0.0, 1.0);
		albedo = mix(albedo, snow_color, bury);
		grass_rough = mix(roughness_value, 0.55, bury);
	}

	// Darken at night so the moon's directional light can't make turf glow.
	albedo *= 1.0 - night_factor * night_darkness;

	ALPHA = alpha;
	ALBEDO = albedo;
	ROUGHNESS = grass_rough;
	METALLIC = 0.0;
}
