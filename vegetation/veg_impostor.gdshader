shader_type spatial;
render_mode unshaded, cull_disabled, depth_prepass_alpha;

// Distant-tree impostor (veg overhaul Phase 3b): ONE camera-facing quad per
// tree sampling a 3x3 baked atlas (8 yaw views + 1 top view) of the real
// parametric NEAR mesh. Cylindrical billboard + view-frame selection are done
// manually in this shader (spatial shaders have no billboard render_mode —
// same technique as vegetation/camp_glow.gdshader). The mask atlas marks
// foliage vs bark pixels so the SAME seasonal uniforms the leaf shaders use
// (autumn / leaf_coverage / winter, pushed by VegetationEnvironmentSync — the
// names must match foliage.gdshader) recolor and thin leaves while trunks
// stay, keeping the impostor tier season-consistent with the near tiers.
// Octahedral-impostor math reference: wojtekpil/Godot-Octahedral-Impostors
// (MIT); this is a simpler yaw-ring variant written for this project.

#include "res://core/soi/shaders/soi_clip.gdshaderinc"
#include "res://vegetation/leaf_phenology.gdshaderinc"
#include "res://vegetation/veg_growth.gdshaderinc"

uniform sampler2D atlas_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D mask_tex : filter_linear, repeat_disable, hint_default_black;
uniform float frames_x = 3.0;
uniform float frames_y = 3.0;
uniform float yaw_frames = 8.0;
uniform float has_top = 1.0;

// Seasonal set — names mirror foliage.gdshader so env-sync pushes apply.
uniform float autumn : hint_range(0.0, 1.0) = 0.0;
uniform float leaf_coverage : hint_range(0.0, 1.0) = 1.0;
uniform float spring_bud : hint_range(0.0, 1.0) = 0.0;
uniform float winter : hint_range(0.0, 1.0) = 0.0;
uniform float snow_amount : hint_range(0.0, 1.0) = 0.0;
uniform float snow_depth_m = 0.0;
uniform float summer : hint_range(0.0, 1.0) = 1.0;
uniform float deciduousness : hint_range(0.0, 1.0) = 0.8;
uniform float night_factor : hint_range(0.0, 1.0) = 0.0;
// The card's brightness floor once night_factor saturates. Pushed live by
// VegetationEnvironmentSync as (scene ambient / day ambient) × 0.35, i.e. the
// same composition a LIT tree lands on at that instant (albedo × the
// night_darkness leftover × ambient). The old hard-coded 0.30 floor left the
// far forest ~2 orders of magnitude brighter than the near tier at full night
// — glowing cutouts on a dark horizon, near blooming once the night
// glow_hdr_threshold drops to 0.6 (main.gd's glow setup).
uniform float night_ambient_mul : hint_range(0.0, 1.0) = 0.0035;
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 autumn_warm : source_color = vec3(0.96, 0.78, 0.12);
uniform vec3 autumn_orange : source_color = vec3(0.93, 0.45, 0.06);
uniform vec3 autumn_hot : source_color = vec3(0.80, 0.13, 0.04);
// Live wind. Uniform names shared with wind_vertex.gdshaderinc so
// VegetationWindDriver pushes the SAME weather (incl. extreme-weather
// multipliers) here as to the near tiers — the old private `wind_speed`
// uniform meant distant forests sat frozen at a fixed 0.02 sway while a
// storm thrashed the near trees. `wind_strength` stays the base amplitude
// knob; speed scales it (capped ~36 m/s like the include's own curve).
uniform float wind_strength = 0.02;
uniform float wind_speed_ms = 2.0;
uniform float gust_intensity : hint_range(0.0, 1.0) = 0.0;
uniform vec2 wind_direction = vec2(0.0, 1.0);

// SNAG. The atlas is a bake of the tree in full leaf, so the stem behind the
// foliage was never drawn — a declining tree that only DROPPED foliage pixels
// dissolved into a few dots on a stub. The stem is drawn procedurally instead:
// a tapered band down the card's centre line, revealed wherever foliage has
// gone. Quad size + stem radius are in metres of the MATURE tree.
uniform float snag_world_w = 8.0;
uniform float snag_world_h = 8.0;
uniform float snag_trunk_radius = 0.0;
uniform vec3 snag_color : source_color = vec3(0.21, 0.18, 0.15);

varying vec3 v_origin;
varying float v_rel_yaw;
varying float v_elev;
varying float v_growth_leaf;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	// Growth: the baked card is the MATURE tree, so the quad itself is scaled —
	// height and width separately, like the 3D tiers it stands in for.
	float g_gen;
	vec4 g_st = veg_growth_state(INSTANCE_CUSTOM, g_gen);
	vec3 g_var = veg_growth_generation(g_gen, INSTANCE_CUSTOM.w);
	v_growth_leaf = g_st.w;
	origin.xz += g_var.yz * step(0.0001, g_st.x);
	v_origin = origin;
	// Instance yaw + scale straight from the instance basis (rotation about Y
	// by t gives basis.x = (cos t, 0, -sin t)).
	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);
	float yaw = atan(-MODEL_MATRIX[0].z, MODEL_MATRIX[0].x);
	vec3 to_cam = CAMERA_POSITION_WORLD - origin;
	float az = atan(to_cam.x, to_cam.z);
	v_rel_yaw = az - yaw;
	v_elev = atan(to_cam.y, max(length(to_cam.xz), 0.001));
	// Cylindrical billboard: quad local X spans width, Y spans height.
	vec2 fwd = normalize(to_cam.xz + vec2(0.0001));
	vec3 right = vec3(fwd.y, 0.0, -fwd.x);
	// A vertical card viewed from high above degenerates to an edge-on sliver
	// (reads as a dark plank from the drone). Tilt the card's vertical axis
	// toward the camera in step with the top-view texture blend so overhead
	// views see a flat, top-textured card instead.
	vec3 up_axis = vec3(0.0, 1.0, 0.0);
	if (has_top > 0.5) {
		float t_top = smoothstep(0.85, 1.25, atan(to_cam.y, max(length(to_cam.xz), 0.001)));
		if (t_top > 0.001) {
			vec3 flat_axis = cross(right, normalize(to_cam));
			if (length(flat_axis) > 0.001) {
				up_axis = normalize(mix(up_axis, normalize(flat_axis), t_top));
			}
		}
	}
	// Distant sway: whole-tree lean, stronger at the top of the quad, scaled
	// by live wind speed (same 12 m/s reference + 3.0 cap as the near tiers'
	// wind_vertex.gdshaderinc) with a faster gust wobble on top and a static
	// downwind lean projected onto the card's own axis.
	float speed_t = clamp(wind_speed_ms / 12.0, 0.05, 3.0);
	float amp = wind_strength * (0.6 + speed_t * 0.9);
	float freq = 0.5 + speed_t * 0.35;
	float phase = origin.x * 0.37 + origin.z * 0.53;
	float osc = sin(TIME * freq + phase)
		+ gust_intensity * 0.55 * sin(TIME * freq * 2.7 + phase * 1.7);
	vec2 w2 = normalize(wind_direction + vec2(1e-4, 0.0));
	float along = dot(vec2(right.x, right.z), w2);
	float sway = amp * (osc * mix(0.35, 1.0, abs(along))
		+ 0.30 * speed_t * along) * VERTEX.y;
	float g_w = g_st.y * g_var.x;
	float g_h = g_st.x * g_var.x;
	vec3 wp = origin + right * (VERTEX.x * sx * g_w) + up_axis * (VERTEX.y * sy * g_h)
		+ right * (sway * g_h);
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(wp, 1.0);
}

vec2 cell_uv(vec2 uv, float frame) {
	float col = mod(frame, frames_x);
	float row = floor(frame / frames_x);
	return (clamp(uv, 0.001, 0.999) + vec2(col, row)) / vec2(frames_x, frames_y);
}

void fragment() {
	soi_clip_fragment(v_origin);
	// Nearest yaw frame; the ring wraps.
	float step_rad = TAU / yaw_frames;
	float f = round(v_rel_yaw / step_rad);
	float frame = mod(mod(f, yaw_frames) + yaw_frames, yaw_frames);
	vec2 uv = UV;
	vec4 col = texture(atlas_tex, cell_uv(uv, frame));
	float m = texture(mask_tex, cell_uv(uv, frame)).r;
	// Steep look-down blends toward the baked top view.
	if (has_top > 0.5) {
		float t = smoothstep(0.85, 1.25, v_elev);
		if (t > 0.001) {
			vec4 top = texture(atlas_tex, cell_uv(uv, yaw_frames));
			float tm = texture(mask_tex, cell_uv(uv, yaw_frames)).r;
			col = mix(col, top, t);
			m = mix(m, tm, t);
		}
	}
	// Seasonal response on FOLIAGE pixels only (mask ≈ 1); bark unaffected.
	// `foliage` is the mask alone — winter dormancy greys an evergreen's needles
	// too, exactly as it does in the near tiers — while leaf fall and autumn
	// colour additionally require deciduousness.
	float foliage = smoothstep(0.35, 0.65, m);
	float leafy = foliage * deciduousness;
	// Leaf fall: drop a coverage-proportional share of leaf pixels, keyed on the
	// atlas UV + a per-tree seed so the thinning holds still (shared law with
	// the card and leaf-shell tiers).
	float inst_seed = hash21(floor(v_origin.xz * 0.5) + 0.5);
	vec2 leaf_key = floor(uv * 96.0) + vec2(inst_seed * 19.3, inst_seed * 7.7);
	// A declining tree thins to its bare stem: foliage pixels go, and the stem
	// they were hiding is drawn in their place (never in the top-down view,
	// where a centre-line band would read as a plank across the crown).
	bool gone = col.a < 0.5 || veg_leaf_fallen(leaf_key, leaf_coverage, leafy)
		|| (foliage > 0.5 && veg_growth_leaf_gone(leaf_key, v_growth_leaf));
	float stem_up = 1.0 - uv.y;
	float stem_r = max(snag_trunk_radius, 0.2) * mix(1.0, 0.12, stem_up);
	float stem = step(abs(uv.x - 0.5) * snag_world_w, stem_r) * step(stem_up, 0.97)
		* step(v_growth_leaf, 0.998) * step(0.0001, snag_trunk_radius)
		* step(v_elev, 0.85);
	if (gone && stem < 0.5) {
		discard;
	}
	float snag = gone ? 1.0 : 0.0;
	foliage *= 1.0 - snag;
	leafy *= 1.0 - snag;
	vec3 albedo = mix(col.rgb, snag_color, snag);
	float svar = veg_phenology_hash(vec2(inst_seed * 73.1, inst_seed * 11.7));
	albedo = veg_apply_bud(albedo, spring_bud * leafy, vec3(0.55, 0.78, 0.24));
	albedo = veg_apply_autumn(albedo, autumn * leafy, svar,
		autumn_warm, autumn_orange, autumn_hot);
	albedo = veg_apply_winter(albedo, winter * foliage);
	if (snow_amount > 0.001 && foliage > 0.001) {
		// Evergreens hold more snow than bare deciduous branches — the same
		// `hold` weighting the near-tier canopy shaders use.
		float hold = mix(0.6, 1.0, 1.0 - deciduousness);
		albedo = mix(albedo, vec3(0.92, 0.94, 0.97),
			snow_amount * foliage * hold * 0.55 * clamp(UV.y + 0.35, 0.0, 1.0));
	}
	// Unshaded card: the atlas is baked evenly lit, so day/night comes from
	// the same uniforms the env sync already pushes (no light pass on
	// thousands of distant quads — this tier must stay cheap). The night end
	// tracks the LIVE scene ambient (see night_ambient_mul above) so dusk
	// fades continuously and full night lands where the lit near tier does.
	float sun_up = clamp(sun_direction.y * 2.0 + 0.35, 0.0, 1.0);
	float light_mul = mix(night_ambient_mul, mix(0.55, 1.0, sun_up), 1.0 - night_factor);
	ALBEDO = albedo * light_mul;
}
