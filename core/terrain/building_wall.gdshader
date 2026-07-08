shader_type spatial;

// OSM building walls: five procedural material modes, no texture fetches.
//   0 LAP        horizontal lap-board siding (the original look — unchanged)
//   1 TRAILER    ribbed mobile-home aluminum, faded paint + oxidation streaks
//   2 CORRUGATED vertical corrugated steel, rust blooming near the ground
//   3 PLYWOOD    T1-11 vertical-groove plywood, per-panel paint jitter
//   4 STUCCO     stucco / CMU render, fine grain + faint block seams
// Mesh contract (BuildingBuilder): UV.x = metres along the facade, UV.y =
// metres above the building base (negative = foundation skirt); COLOR.rgb =
// per-building wall tint; UV2.x = mode + 0.5, UV2.y = per-building weathering
// seed 0..1. Meshes with no UV2 read (0,0) → mode 0 with zero seed, i.e. the
// pre-mode look, so old meshes and the modal studio stay identical.
render_mode cull_disabled, diffuse_lambert, specular_schlick_ggx;

uniform float board_height_m : hint_range(0.10, 0.50) = 0.22;
uniform float seam_strength : hint_range(0.0, 1.0) = 0.45;
uniform float color_jitter : hint_range(0.0, 0.30) = 0.07;
uniform float wall_roughness : hint_range(0.3, 1.0) = 0.85;
uniform vec4 foundation_color : source_color = vec4(0.52, 0.52, 0.50, 1.0);
// Desert-town wear on modes 1–4 (mode 0 is untouched): dirt skirt in the
// bottom half-metre, sun fade higher up, oxidation on the metal modes.
// Scaled per building by the UV2 seed so a row never weathers uniformly.
uniform float weathering : hint_range(0.0, 1.0) = 0.55;
// Optional real facade texture (styled hero buildings only): tiled in metric
// wall UVs — wall_tex_size_m is the real-world size one tile covers — so a
// 4×3 m photo strip repeats at true scale. Replaces the procedural mode above
// the foundation line; the dirt skirt still applies so tiles don't float.
uniform bool use_wall_tex = false;
uniform sampler2D wall_tex : source_color, filter_linear_mipmap;
uniform vec2 wall_tex_size_m = vec2(4.0, 3.0);
uniform float snow_amount : hint_range(0.0, 1.0) = 0.0;
uniform float snow_depth_m = 0.0;
uniform vec3 snow_color : source_color = vec3(0.90, 0.93, 0.98);

#include "res://core/soi/shaders/soi_clip.gdshaderinc"

varying vec2 v_mode_seed;
varying vec3 v_world_pos;
varying vec3 v_world_normal;

float hash1(float p) {
	return fract(sin(p * 127.1) * 43758.5453);
}

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

void vertex() {
	v_mode_seed = UV2;
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	soi_clip_fragment(v_world_pos);
	// Backfaces (cull_disabled: floor cap, odd OSM footprints) light correctly.
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}

	int mode = int(floor(v_mode_seed.x));
	float seed = v_mode_seed.y;
	float wear = weathering * (0.55 + 0.9 * seed);

	float v = UV.y;
	float band = v / board_height_m;
	float det = clamp(fwidth(band) * 2.0, 0.0, 1.0);
	float aa = fwidth(band) * 1.5 + 1e-4;

	float shade = 1.0;
	float metal = 0.0;
	float rough = wall_roughness;
	vec3 tint = COLOR.rgb;

	if (mode == 1) {
		// TRAILER: narrow horizontal ribs, soft sinusoidal shading (rolled
		// aluminum, not overlapped boards), faded paint, rust streaks bleeding
		// down from fastener lines.
		float rib = sin(TAU * v / 0.08);
		shade = 1.0 + 0.09 * rib;
		shade = mix(shade, 1.0, clamp(fwidth(v / 0.08) * 2.0, 0.0, 1.0));
		// Sun-faded paint: desaturate + lighten with wear.
		float fade = 0.35 * wear;
		tint = mix(tint, vec3(dot(tint, vec3(0.333)) * 1.25 + 0.08), fade);
		// Vertical oxidation streaks, anchored per-facade-metre.
		float streak = vnoise(vec2(UV.x * 1.7 + seed * 31.0, v * 0.25));
		float rust_amt = wear * 0.5 * smoothstep(0.55, 0.9, streak);
		tint = mix(tint, vec3(0.42, 0.27, 0.18), rust_amt);
		metal = 0.30;
		rough = 0.55 + 0.3 * wear;
	} else if (mode == 2) {
		// CORRUGATED: vertical ribs, semi-gloss steel, rust blooming from the
		// ground line and in noisy patches.
		float rib = sin(TAU * UV.x / 0.075);
		shade = 1.0 + 0.13 * rib;
		shade = mix(shade, 1.0, clamp(fwidth(UV.x / 0.075) * 2.0, 0.0, 1.0));
		float patch = vnoise(vec2(UV.x * 0.8 + seed * 17.0, v * 0.8));
		float ground_rust = smoothstep(1.4, 0.0, v);
		float rust_amt = wear * clamp(0.65 * ground_rust + 0.45 * smoothstep(0.6, 0.95, patch), 0.0, 1.0);
		tint = mix(tint, vec3(0.45, 0.26, 0.15), rust_amt);
		metal = mix(0.6, 0.05, rust_amt);
		rough = mix(0.45, 0.95, rust_amt);
	} else if (mode == 3) {
		// PLYWOOD / T1-11: matte vertical grooves every 0.2 m, strong paint
		// jitter per 1.2 m sheet.
		float g = fract(UV.x / 0.2);
		float gaa = fwidth(UV.x / 0.2) * 1.5 + 1e-4;
		float groove = 1.0 - 0.35 * (smoothstep(0.06 + gaa, 0.0, g) + smoothstep(1.0 - 0.06 - gaa, 1.0, g));
		float sheet = floor(UV.x / 1.22);
		float pj = (hash1(sheet + seed * 100.0) - 0.5) * 2.0 * (color_jitter + 0.06);
		shade = (1.0 + pj) * groove;
		shade = mix(shade, 1.0, clamp(fwidth(UV.x / 0.2) * 2.0, 0.0, 1.0));
		// Weather-grayed wood showing through thin paint near the bottom.
		float peel = wear * 0.3 * smoothstep(1.0, 0.0, v) * vnoise(vec2(UV.x * 3.0, v * 3.0 + seed * 9.0));
		tint = mix(tint, vec3(0.48, 0.44, 0.38), peel);
		rough = 0.92;
	} else if (mode == 4) {
		// STUCCO / CMU: fine grain, faint 0.4 m block courses, no boards.
		float grain = 0.94 + 0.12 * vnoise(UV * 8.0);
		float course = fract(v / 0.4);
		float caa = fwidth(v / 0.4) * 1.5 + 1e-4;
		float seams = 1.0 - 0.07 * smoothstep(0.05 + caa, 0.0, course);
		shade = grain * seams;
		shade = mix(shade, grain, clamp(fwidth(v / 0.4) * 2.0, 0.0, 1.0));
		rough = 0.95;
	} else {
		// LAP (mode 0): the original lap-board path, kept byte-identical.
		float bidx = floor(band);
		float fy = fract(band);
		float jitter = (hash1(bidx) - 0.5) * 2.0 * color_jitter;
		float seam = 1.0 - seam_strength * smoothstep(1.0 - 0.12 - aa, 1.0, fy);
		shade = (1.0 + jitter) * seam;
		shade = mix(shade, 1.0, det);
	}

	// Broad weathering wash so big facades don't read as one flat paint job.
	float wash = 1.0 + (vnoise(UV * 0.35) - 0.5) * 0.08;
	vec3 wall_rgb = tint * shade * wash;

	if (use_wall_tex && v >= 0.0) {
		wall_rgb = texture(wall_tex, UV / wall_tex_size_m).rgb * wash;
		metal = 0.0;
		rough = wall_roughness;
		// Grounding dirt so a photo tile doesn't read as a fresh decal.
		float tex_dirt = weathering * 0.25 * smoothstep(0.5, 0.0, v);
		wall_rgb = mix(wall_rgb, wall_rgb * vec3(0.6, 0.55, 0.5), tex_dirt);
	} else if (mode != 0) {
		float dirt = wear * 0.30 * smoothstep(0.6, 0.0, v) * step(0.0, v);
		wall_rgb = mix(wall_rgb, wall_rgb * vec3(0.55, 0.50, 0.45), dirt);
		float sun = wear * 0.18 * smoothstep(1.2, 3.5, v);
		wall_rgb = mix(wall_rgb, wall_rgb * 1.18 + 0.03, sun);
	}

	// Foundation concrete below the base line (the skirt's V is negative).
	float fnd = smoothstep(0.0, -0.02, v);
	vec3 fnd_rgb = foundation_color.rgb * (0.92 + 0.16 * vnoise(UV * 3.0));

	ALBEDO = mix(wall_rgb, fnd_rgb, fnd);
	ROUGHNESS = mix(rough, 0.9, fnd);
	METALLIC = metal * (1.0 - fnd);
	if (snow_amount > 0.001 || snow_depth_m > 0.001) {
		float depth_t = clamp(snow_depth_m / 1.5, 0.0, 1.0);
		float up = clamp(v_world_normal.y, 0.0, 1.0);
		float ledge = smoothstep(0.72, 0.96, up);
		float cov = clamp(snow_amount * 0.35 + depth_t * 0.7, 0.0, 1.0) * ledge;
		ALBEDO = mix(ALBEDO, snow_color, cov);
		ROUGHNESS = mix(ROUGHNESS, 0.92, cov);
	}
	SPECULAR = 0.25;
}
