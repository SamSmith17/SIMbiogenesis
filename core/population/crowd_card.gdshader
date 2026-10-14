shader_type spatial;
// The far tier of the crowd: past `figure_dist` every person is a camera-
// facing dot of constant APPARENT size, so the settlement view at 1200 m
// still shows a thousand pastel marks where a thousand people are — instead
// of nobody. Same slot layout as crowd_figure.gdshader (the two MultiMeshes
// hold the same people; this one draws only where that one collapses).
// Apparent size is computed in VIEW space, never from VIEWPORT_SIZE (see
// camp_glow.gdshader for why).
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_opaque;

uniform float t_rel = 0.0;
uniform float figure_dist = 150.0;
uniform float card_dist = 3000.0;    // nothing draws beyond this
uniform float lod_dist = 0.0;
uniform float draw_mode = 1.0;
uniform float light_draw = 1.0;      // 0 = no dots for the LIGHT tier (slots below full_base)
uniform float full_base = 1e9;
uniform float world_size = 0.9;      // metres across when close enough to matter
uniform float min_angular = 0.0045;  // ≈ constant on-screen size beyond the crossover
uniform float max_world_size = 40.0;
uniform float night_glow = 0.0;      // lifted at night so the field reads like lights
// 0 by day .. 1 at night (Main pushes it): a far person's glow sticks read
// as a coloured point of light.
global uniform float npc_night;
global uniform float fx_time_npc;
const float PEAK_RAMP_H = 0.012;
const vec3 PEAK_GREEN = vec3(0.35, 1.0, 0.45);
const vec3 MOOD_WARM = vec3(1.0, 0.78, 0.48);
// The glow is reserved for people CLOSE to FUCK YES: nothing below ~35 %
// charge, then a steep ease-in (cubic) — 60 % is a hint, 80 % clearly lit,
// 95 % blazing. A merely happy person ("Fuck Maybe", "Fuck It!") stays a
// black figure; the old linear morale glow lit half the crowd and by day read
// as flat green.
float glow_ramp(float b) {
	float t = smoothstep(0.35, 1.0, b);
	return t * t * t;
}
uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform vec4 height_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform float height_ready = 0.0;

varying vec3 v_tint;
varying float v_show;
varying vec3 v_glow_col;
varying float v_glow;
varying float v_mood;
varying float v_peak;
varying float v_pseed;
varying float v_buzz;

void vertex() {
	vec3 a = MODEL_MATRIX[0].xyz;
	vec3 b = MODEL_MATRIX[1].xyz;
	float t0 = MODEL_MATRIX[2].x;
	float t1 = MODEL_MATRIX[2].y;
	float flags = MODEL_MATRIX[3].z;
	float seed = MODEL_MATRIX[3].y;
	v_tint = COLOR.rgb;
	v_pseed = seed;
	// NpcPeak.pack_mood (see crowd_figure.gdshader).
	if (COLOR.a >= 48.0) {
		v_mood = 1.0;
		v_buzz = 1.0;
		v_peak = smoothstep(0.0, PEAK_RAMP_H, t_rel - (COLOR.a - 64.0));
	} else {
		float q = floor(COLOR.a);
		v_mood = clamp((COLOR.a - q) / 0.999, 0.0, 1.0);
		v_buzz = q / 31.0;
		v_peak = 0.0;
	}
	// Same glow-carrier test and palette as crowd_figure.gdshader.
	v_glow = fract(seed * 13.7) < 0.72 ? 1.0 : 0.0;
	int gi = int(floor(fract(seed * 5.3) * 6.0));
	v_glow_col = gi == 0 ? vec3(0.25, 1.0, 0.35) : gi == 1 ? vec3(1.0, 0.22, 0.72)
		: gi == 2 ? vec3(0.2, 0.85, 1.0) : gi == 3 ? vec3(1.0, 0.92, 0.22)
		: gi == 4 ? vec3(1.0, 0.5, 0.12) : vec3(0.62, 0.32, 1.0);
	float span = max(t1 - t0, 1e-6);
	float u = clamp((t_rel - t0) / span, 0.0, 1.0);
	vec3 p = mix(a, b, u);
	if (height_ready > 0.5) {
		vec2 huv = (p.xz - height_rect.xy) / max(height_rect.zw, vec2(1e-3));
		if (huv.x >= 0.0 && huv.x <= 1.0 && huv.y >= 0.0 && huv.y <= 1.0) {
			p.y = textureLod(height_tex, huv, 0.0).r;
		}
	}
	p += vec3(0.0, 0.9 + max(-flags, 0.0), 0.0);   // chest height (+ a DJ's deck)
	vec4 origin_view = VIEW_MATRIX * vec4(p, 1.0);
	float dist = max(-origin_view.z, 0.001);
	float far = distance(p, CAMERA_POSITION_WORLD);
	bool show = flags < 1.0 && draw_mode > 0.5 && far >= figure_dist && far <= card_dist
		&& (light_draw > 0.5 || float(INSTANCE_ID) >= full_base)
		&& (lod_dist <= 0.0 || far <= lod_dist);
	v_show = show ? 1.0 : 0.0;
	float s = clamp(dist * min_angular, world_size, max_world_size);
	vec3 view_pos = origin_view.xyz + vec3(VERTEX.x, VERTEX.y, 0.0) * s;
	if (!show) {
		view_pos = vec3(0.0, 0.0, 1.0);
	}
	POSITION = PROJECTION_MATRIX * vec4(view_pos, 1.0);
}

void fragment() {
	vec2 d = UV - vec2(0.5);
	float r = length(d) * 2.0;
	if (v_show < 0.5 || r > 1.0) {
		discard;
	}
	// A dark body with the pastel rim, like the figure up close.
	float edge = smoothstep(0.55, 1.0, r);
	ALBEDO = mix(vec3(0.03, 0.035, 0.05), v_tint, edge * 0.9);
	EMISSION = v_tint * (0.12 + night_glow) * edge;
	float core = 1.0 - smoothstep(0.0, 0.6, r);
	if (v_glow > 0.5 && npc_night > 0.01) {
		// A far crowd at night: a faint point of the wristbands' colour.
		EMISSION += v_glow_col * npc_night * 0.5 * core;
	}
	// Catching it (only near FUCK YES, glow_ramp): a green RING round the
	// dark dot. A peak is the green dot — a far view shows the peak spreading
	// as green patches — dimmer by day so the crowd stays dark.
	float bz = glow_ramp(v_buzz) * (1.0 - v_peak);
	if (bz > 0.002) {
		EMISSION += PEAK_GREEN * bz * (0.45 + 0.4 * sin(fx_time_npc * 3.2)) * edge * 1.6;
	}
	if (v_peak > 0.0) {
		float pulse = 0.72 + 0.28 * sin(fx_time_npc * 1.6);
		ALBEDO = mix(ALBEDO, PEAK_GREEN * 0.3, v_peak * mix(0.3, 1.0, npc_night));
		EMISSION += PEAK_GREEN * v_peak * pulse * (mix(0.5, 1.8, npc_night) * core + 0.6);
	}
}
