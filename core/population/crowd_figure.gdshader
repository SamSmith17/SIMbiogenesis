shader_type spatial;
// The light-tier crowd: one MultiMesh, one draw call, every person drawn
// from a SLOT the sim writes once per EVENT and the GPU reads every frame.
//
// The instance "transform" is not a transform — it is data (see
// CrowdRenderer.write_slot):
//   basis.x = segment start (world xyz)     basis.y = segment end (world xyz)
//   basis.z = (t0, t1, yaw_hint)  — sim hours relative to `time_base`
//   origin  = (pose, seed, flags, 0)
// Position is `mix(a, b, (t_rel - t0) / (t1 - t0))`: motion needs no CPU, and
// it scrubs backwards within a segment for free. COLOR is the person's pastel
// (instance color); UV2 tags the body part + limb fraction (CrowdFigureMesh).
//
// LOD lives HERE: past `figure_dist` the vertices collapse behind the clip
// plane (the card shader takes over); a hidden flag or draw mode 0 does the
// same. No CPU visibility sweeps — the AMD rule from the vegetation tiers.
//
// Lit like npc_silhouette.gdshader (near-black body, pastel fresnel rim), so a
// crowd figure and a full-tier avatar read as the same kind of someone.
render_mode cull_back, diffuse_lambert, specular_schlick_ggx, shadows_disabled, skip_vertex_transform;

// Cosmetic clock (SimFxRate): advances with the sim, time-lapsed and
// capped, frozen dead while paused. Replaces TIME, which never stops.
global uniform float fx_time_npc;
// 0 by day .. 1 at full night (Main pushes DaylightModel.night_amount):
// lights the glow sticks.
global uniform float npc_night;
// THE BEAT (StageBeat.push_shader): the four playing stages nearest the
// camera. pos = (x, z, radius — 0 = empty slot, energy 0..1); beat =
// (beats since the music started, mod 128; seconds until the next drop, 99
// = none known; build 0..1; drop pulse 1 -> 0 after a drop).
global uniform vec4 music_pos0;
global uniform vec4 music_pos1;
global uniform vec4 music_pos2;
global uniform vec4 music_pos3;
global uniform vec4 music_beat0;
global uniform vec4 music_beat1;
global uniform vec4 music_beat2;
global uniform vec4 music_beat3;
// StageBeat.ANTICIPATE_S: the run-up the crowd and the DJ react in.
const float MUSIC_ANTICIPATE_S = 4.0;

uniform float t_rel = 0.0;           // sim hours since CrowdRenderer.time_base
uniform float figure_dist = 150.0;   // metres: beyond this the card draws instead
uniform float lod_dist = 0.0;        // > 0: nothing draws beyond this (the "lod" pref)
uniform float draw_mode = 1.0;       // 0 = hide everything
uniform float light_draw = 1.0;      // 0 = the LIGHT tier (slots below full_base) is drawn only near:
                                     //     faded out over the last LIGHT_FADE of figure_dist, no dots
uniform float full_base = 1e9;       // first slot of the full-tier people the host handed over
uniform vec4 body_color : source_color = vec4(0.022, 0.026, 0.038, 1.0);
uniform float rim_power : hint_range(0.5, 16.0) = 6.5;
uniform float rim_strength : hint_range(0.0, 2.0) = 0.85;
uniform float rim_emission : hint_range(0.0, 1.0) = 0.16;
uniform float stride_m = 0.75;
// Height raster over the population region (CrowdRenderer bakes it from the
// terrain): R = ground height. Inside the rect the figure's feet follow it
// EVERY frame along the segment; outside (or before the bake lands) the
// segment's endpoint heights interpolate linearly — which over a hill is a
// person in the air or under the ground, the bug this exists to fix.
uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform vec4 height_rect = vec4(0.0, 0.0, 1.0, 1.0);   // origin.x, origin.z, size.x, size.z
uniform float height_ready = 0.0;

// Joint pivots — MUST match CrowdFigureMesh.
const vec3 PIVOT_SHOULDER_L = vec3(-0.22, 1.42, 0.0);
const vec3 PIVOT_SHOULDER_R = vec3(0.22, 1.42, 0.0);
const vec3 PIVOT_HIP_L = vec3(-0.10, 0.86, 0.0);
const vec3 PIVOT_HIP_R = vec3(0.10, 0.86, 0.0);
const vec3 PIVOT_WAIST = vec3(0.0, 0.86, 0.0);
const vec3 PIVOT_NECK = vec3(0.0, 1.47, 0.0);

// Pose codes (CrowdCohort.pose_code).
const float POSE_STAND = 0.0;
const float POSE_WALK = 1.0;
const float POSE_SIT = 2.0;
const float POSE_LIE = 3.0;
const float POSE_DANCE = 4.0;
const float POSE_WORK = 5.0;
const float POSE_QUEUE = 6.0;
const float POSE_RAVE = 7.0;
const float POSE_TALK = 8.0;
const float POSE_CHEER = 9.0;
const float POSE_DJ = 10.0;
const float POSE_PEAK = 11.0;
// Ground poses + the burn's roles (CrowdCohort POSE_CROSS..POSE_GAZE).
const float POSE_CROSS = 12.0;
const float POSE_LOUNGE = 13.0;
const float POSE_KNEEL = 14.0;
const float POSE_REDIRECT = 15.0;
const float POSE_FIREFLOW = 16.0;
const float POSE_GAZE = 17.0;
// A light dance on the spot (a fire with a stage's music carrying over).
const float POSE_SWAY = 18.0;
// Peak experience: ramp-in and ignition flash, in SIM hours from the onset
// (so a spreading peak is drawn as neighbours lighting up one after another).
const float PEAK_RAMP_H = 0.012;
const float PEAK_FLASH_H = 0.006;
const vec3 PEAK_GREEN = vec3(0.35, 1.0, 0.45);
// The MOOD glow is one warm amber for everyone — NOT the identity pastel:
// a green-tinted person glowing with a good mood read as a peak. Green means
// FUCK YES! and nothing else.
const vec3 MOOD_WARM = vec3(1.0, 0.78, 0.48);

varying vec3 v_tint;
// Glow sticks / EL wire: the REST-pose coordinates the fragment stage tests
// for a band (part, limb fraction, rest height) and the person's style
// (< 0 = carries none), plus the colour. Tested PER FRAGMENT on interpolated
// values: the capsules have no vertex rings inside a 7 cm band, so a
// per-vertex test tagged nothing and no band ever drew.
// MOOD (CrowdRenderer.pack_mood in COLOR.a): v_mood 0..1 how good a time
// they are having; v_peak 0..1 the FUCK YES! glow (ramped in from the onset),
// v_flash the brief ignition burst.
varying float v_mood;
varying float v_fade;   // 1 = solid; below 1 a screen-door dissolve (never a pop)
varying float v_peak;
varying float v_flash;
// BUZZ (0..1): how close they are to FUCK YES (NpcPeak charge / threshold).
varying float v_buzz;
varying flat float v_seed;
varying flat float v_glow_part;
varying float v_glow_frac;
varying float v_glow_y;
varying flat float v_glow_style;
varying vec3 v_glow_col;

vec3 glow_palette(float k) {
	int i = int(floor(fract(k) * 6.0));
	if (i == 0) return vec3(0.25, 1.0, 0.35);
	if (i == 1) return vec3(1.0, 0.22, 0.72);
	if (i == 2) return vec3(0.2, 0.85, 1.0);
	if (i == 3) return vec3(1.0, 0.92, 0.22);
	if (i == 4) return vec3(1.0, 0.5, 0.12);
	return vec3(0.62, 0.32, 1.0);
}

// The glow is reserved for people CLOSE to FUCK YES: nothing below ~35 %
// charge, then a steep ease-in (cubic) — 60 % is a hint, 80 % clearly lit,
// 95 % blazing. A merely happy person ("Fuck Maybe", "Fuck It!") stays a
// black figure; the old linear morale glow lit half the crowd and by day read
// as flat green.
float glow_ramp(float b) {
	float t = smoothstep(0.35, 1.0, b);
	return t * t * t;
}

mat3 rot_x(float a) {
	float c = cos(a);
	float s = sin(a);
	return mat3(vec3(1.0, 0.0, 0.0), vec3(0.0, c, s), vec3(0.0, -s, c));
}

mat3 rot_z(float a) {
	float c = cos(a);
	float s = sin(a);
	return mat3(vec3(c, s, 0.0), vec3(-s, c, 0.0), vec3(0.0, 0.0, 1.0));
}

mat3 rot_y(float a) {
	float c = cos(a);
	float s = sin(a);
	return mat3(vec3(c, 0.0, -s), vec3(0.0, 1.0, 0.0), vec3(s, 0.0, c));
}

// The music reaching `xz` (the nearest playing stage within its radius):
// x = beat (-1 = silence), y = energy, z = drop pulse, w = anticipation 0..1
// through the last MUSIC_ANTICIPATE_S before a drop. Mirrors StageBeat.at.
vec4 music_at(vec2 xz) {
	vec4 P[4] = vec4[4](music_pos0, music_pos1, music_pos2, music_pos3);
	vec4 B[4] = vec4[4](music_beat0, music_beat1, music_beat2, music_beat3);
	vec4 best = vec4(-1.0, 1.0, 0.0, 0.0);
	float best_d = 1e9;
	for (int i = 0; i < 4; i++) {
		if (P[i].z <= 0.0) {
			continue;
		}
		float d = distance(xz, P[i].xy);
		if (d <= P[i].z && d < best_d) {
			best_d = d;
			float ant = (B[i].y >= 0.0 && B[i].y <= MUSIC_ANTICIPATE_S) ? 1.0 - B[i].y / MUSIC_ANTICIPATE_S : 0.0;
			best = vec4(B[i].x, P[i].w, B[i].w, ant);
		}
	}
	return best;
}

void vertex() {
	vec3 a = MODEL_MATRIX[0].xyz;
	vec3 b = MODEL_MATRIX[1].xyz;
	float t0 = MODEL_MATRIX[2].x;
	float t1 = MODEL_MATRIX[2].y;
	float yaw_hint = MODEL_MATRIX[2].z;
	float pose = MODEL_MATRIX[3].x;
	float seed = MODEL_MATRIX[3].y;
	float flags = MODEL_MATRIX[3].z;
	// Negative flags = metres above the ground (a DJ on the deck).
	float elev = max(-flags, 0.0);
	v_tint = COLOR.rgb;
	// ~7 in 10 people carry glow: wristbands, a necklace, sometimes a
	// headband, in one of six neon colours.
	float mood_a = COLOR.a;
	v_seed = seed;
	// NpcPeak.pack_mood: >= 48 = peaking (since = a - 64); else the integer
	// part is the buzz in 31 steps and the fraction the morale (x 0.999).
	if (mood_a >= 48.0) {
		float age = t_rel - (mood_a - 64.0);
		v_mood = 1.0;
		v_buzz = 1.0;
		v_peak = smoothstep(0.0, PEAK_RAMP_H, age);
		v_flash = (1.0 - smoothstep(0.0, PEAK_FLASH_H, abs(age - PEAK_RAMP_H * 0.6))) * step(0.0, age);
	} else {
		float q = floor(mood_a);
		v_mood = clamp((mood_a - q) / 0.999, 0.0, 1.0);
		v_buzz = q / 31.0;
		v_peak = 0.0;
		v_flash = 0.0;
	}
	v_glow_part = floor(UV2.x * 5.0 + 0.5);
	v_glow_frac = UV2.y;
	v_glow_y = VERTEX.y;
	// Wristbands only: the BODY glow (mood / peak) is the headline now.
	v_glow_style = fract(seed * 13.7) < 0.72 ? 0.0 : -1.0;
	v_glow_col = glow_palette(seed * 5.3);

	float span = max(t1 - t0, 1e-6);
	float u = clamp((t_rel - t0) / span, 0.0, 1.0);
	vec3 p = mix(a, b, u);
	if (height_ready > 0.5) {
		vec2 huv = (p.xz - height_rect.xy) / max(height_rect.zw, vec2(1e-3));
		if (huv.x >= 0.0 && huv.x <= 1.0 && huv.y >= 0.0 && huv.y <= 1.0) {
			p.y = textureLod(height_tex, huv, 0.0).r;
		}
	}
	p.y += elev;
	vec3 seg = b - a;
	float seg_len = length(seg.xz);
	float dist = distance(p, CAMERA_POSITION_WORLD);
	bool hidden = flags >= 1.0 || draw_mode < 0.5 || dist > figure_dist
		|| (lod_dist > 0.0 && dist > lod_dist);
	// With the distant crowd off, a light-tier figure dissolves out toward
	// the edge of the figure reach instead of handing over to a dot.
	v_fade = (light_draw < 0.5 && float(INSTANCE_ID) < full_base)
		? 1.0 - smoothstep(figure_dist * 0.75, figure_dist, dist) : 1.0;
	if (hidden) {
		VERTEX = vec3(0.0, 0.0, 1.0);   // behind the camera in view space: clipped
		NORMAL = vec3(0.0, 0.0, 1.0);
	} else {
		// Standing people do not all face their anchor dead-on: a per-person
		// stance offset of up to ±25°. Walkers face where they are going.
		// yaw_hint past 500 = a FIXED facing (CrowdRenderer.YAW_FIXED): a short
		// eased glide into a standing spot keeps the person's own facing.
		// A STATIC pose still travelling a long segment is a person on the
		// move: a late event, a tier switch or a hero hand-off eases the
		// figure to its new spot, and a full-tier overflow figure glides to
		// each tick position with its SETTLED pose — drawn rigid, a sleeper
		// slid across the camp lying down. Anything over a short shuffle
		// walks there, facing the way it goes. Dancing poses keep moving in
		// their own pose (a circler, a raver, a fire-flow lane).
		bool static_pose = !(pose == POSE_WALK || pose == POSE_DANCE || pose == POSE_RAVE
			|| pose == POSE_SWAY || pose == POSE_PEAK || pose == POSE_DJ || pose == POSE_FIREFLOW);
		bool moving_far = u < 1.0 && seg_len > 2.0;
		bool fixed_face = yaw_hint > 500.0 && !(static_pose && moving_far);
		float yaw = fixed_face ? yaw_hint - 1000.0 + (seed - 0.5) * 0.9
			: (seg_len > 0.05 ? atan(seg.x, seg.z) : yaw_hint + (seed - 0.5) * 0.9);
		bool walking = u < 1.0 && (pose == POSE_WALK ? seg_len > 0.05 : (static_pose && moving_far));
		// Per-person tempo and throw, so a crowd is not a chorus line.
		float tempo = 0.8 + seed * 0.45;
		float throw = 0.75 + fract(seed * 7.31) * 0.5;
		float part = floor(UV2.x * 5.0 + 0.5);
		float frac = UV2.y;
		vec3 v = VERTEX;
		vec3 n = NORMAL;
		float sway = sin(fx_time_npc * 0.9 * tempo + seed * 6.283) * 0.02 * throw;
		float limb_angle = 0.0;
		vec3 pivot = PIVOT_WAIST;
		if (part == 2.0) { pivot = PIVOT_SHOULDER_L; }
		else if (part == 3.0) { pivot = PIVOT_SHOULDER_R; }
		else if (part == 4.0) { pivot = PIVOT_HIP_L; }
		else if (part == 5.0) { pivot = PIVOT_HIP_R; }
		float body_lower = 0.0;
		float body_tilt = 0.0;
		float yaw_twist = 0.0;
		float head_nod = 0.0;
		// ON THE BEAT: a dancer within earshot of a playing stage moves on its
		// beat (one bounce a beat, half the crowd swaying the other way),
		// throws harder with the energy, puts their hands up through the
		// run-up to a drop (three in four of them) and JUMPS on it.
		bool dances = pose == POSE_DANCE || pose == POSE_RAVE || pose == POSE_SWAY
			|| pose == POSE_PEAK || pose == POSE_DJ;
		vec4 mus = dances ? music_at(p.xz) : vec4(-1.0, 1.0, 0.0, 0.0);
		bool on_beat = mus.x >= 0.0;
		float mbeat = mus.x * PI + (fract(seed * 3.7) < 0.5 ? 0.0 : PI);
		float m_hype = on_beat ? (0.5 + 0.5 * mus.y) * (1.0 + 1.6 * mus.z) : 1.0;
		// Up through the run-up and still up as the drop lands (the jump),
		// easing back into the dance as the drop pulse fades.
		float hands_up = on_beat ? max(smoothstep(0.0, 0.35, mus.w), smoothstep(0.15, 0.6, mus.z))
			* step(fract(seed * 5.9), 0.75) : 0.0;
		// Extra limb freedom for the ground poses: a sideways splay (outward
		// positive) and a length scale (a knee-less leg "folded").
		float limb_splay = 0.0;
		float leg_scale = 1.0;
		// SIGN CONVENTION (measured by core/population/ground_pose_diag.gd):
		// the figure faces +Z (rot_y puts mesh +Z along the walk). A hanging
		// limb rotated by a NEGATIVE limb_angle swings FORWARD (+Z); positive
		// swings it back. A NEGATIVE body_tilt leans the trunk forward,
		// positive leans it back (LIE lies on its back). A positive head_nod
		// tips the head forward (a nod), negative back (looking up).
		if (walking) {
			float ph = (u * seg_len / max(stride_m, 0.1)) * 6.283 + seed * 6.283;
			float swing = sin(ph) * 0.55;
			if (part == 4.0) limb_angle = swing;
			else if (part == 5.0) limb_angle = -swing;
			else if (part == 2.0) limb_angle = -swing * 0.7;
			else if (part == 3.0) limb_angle = swing * 0.7;
			body_lower = -abs(sin(ph)) * 0.03;
		} else if (pose == POSE_SIT) {
			if (part >= 4.0) limb_angle = -1.35;  // thighs forward, as a bench
			body_lower = 0.42;
		} else if (pose == POSE_CROSS) {
			// Cross-legged on the ground: hips down, the (knee-less) legs
			// forward, splayed and SHORTENED so they read as folded; hands
			// toward the knees.
			body_lower = 0.69;
			if (part >= 4.0) { limb_angle = -1.45; limb_splay = 0.75; leg_scale = 0.55; }
			else if (part >= 2.0) { limb_angle = -0.45; limb_splay = 0.15; }
			yaw_twist = sin(fx_time_npc * 0.07 * tempo + seed * 9.0) * 0.25;
			head_nod = sin(fx_time_npc * 0.3 * tempo + seed * 4.0) * 0.06;
		} else if (pose == POSE_LOUNGE) {
			// Legs out, leaning back on straight arms, the head up.
			body_lower = 0.72;
			body_tilt = 0.5;
			if (part >= 4.0) { limb_angle = -1.55; limb_splay = 0.1; }
			else if (part >= 2.0) { limb_angle = 1.15; limb_splay = 0.3; }
			head_nod = 0.35;
		} else if (pose == POSE_KNEEL) {
			// A sandman: kneeling upright, hands on the thighs, watching.
			// Knee-less legs read as thighs swept BACK to the heels.
			body_lower = 0.45;
			if (part >= 4.0) { limb_angle = 0.9; leg_scale = 0.75; limb_splay = 0.06; }
			else if (part >= 2.0) { limb_angle = -0.25; limb_splay = 0.08; }
			yaw_twist = sin(fx_time_npc * 0.25 * tempo + seed * 7.0) * 0.4;
		} else if (pose == POSE_REDIRECT) {
			// Turning someone back: the lead arm out in a slow guiding sweep.
			float sw = sin(fx_time_npc * 1.2 * tempo + seed * 6.283);
			if (part == 3.0) { limb_angle = -1.25 + sw * 0.25; limb_splay = 0.75 + sw * 0.2; }
			else if (part == 2.0) { limb_angle = -0.45; limb_splay = 0.35; }
			body_tilt = -0.1;
		} else if (pose == POSE_FIREFLOW) {
			// Poi: both arms swinging big circles, opposite in phase, the body
			// turning against them, a light step.
			float beat = fx_time_npc * 3.0 * tempo + seed * 6.283;
			if (part == 2.0) { limb_angle = -1.4 + cos(beat * 2.0) * 0.95; limb_splay = 0.55 + sin(beat * 2.0) * 0.4; }
			else if (part == 3.0) { limb_angle = -1.4 - cos(beat * 2.0) * 0.95; limb_splay = 0.55 - sin(beat * 2.0) * 0.4; }
			else if (part == 4.0) limb_angle = max(sin(beat * 0.5), 0.0) * 0.2;
			else if (part == 5.0) limb_angle = max(-sin(beat * 0.5), 0.0) * 0.2;
			body_lower = abs(sin(beat)) * 0.03;
			yaw_twist = sin(beat * 0.25) * 0.45;
		} else if (pose == POSE_GAZE) {
			// Standing, looking UP at the effigy, weight shifting.
			float shift = sin(fx_time_npc * 0.5 * tempo + seed * 6.283);
			sway = shift * 0.035;
			head_nod = -0.5 + sin(fx_time_npc * 0.2 + seed * 3.0) * 0.08;
			yaw_twist = sin(fx_time_npc * 0.15 * tempo + seed * 11.0) * 0.25;
		} else if (pose == POSE_LIE) {
			body_tilt = 1.5;                       // laid back on the ground
			body_lower = 0.78;
		} else if (pose == POSE_DANCE) {
			float beat = on_beat ? mbeat : fx_time_npc * 2.6 * tempo + seed * 6.283;
			if (part == 2.0 || part == 3.0) limb_angle = mix(-2.5 + sin(beat * 2.0) * 0.3 * throw * m_hype,
				-3.0 + sin(beat * 2.0) * 0.08, hands_up);
			body_lower = -abs(sin(beat)) * 0.08 * throw * m_hype;
			sway = sin(beat) * 0.05 * throw;
		} else if (pose == POSE_SWAY) {
			// Dancing LIGHTLY: arms loose and bent at the waist, a soft bob,
			// the body rolling side to side — nothing above the shoulders.
			float beat = on_beat ? mbeat : fx_time_npc * 1.7 * tempo + seed * 6.283;
			if (part == 2.0 || part == 3.0) limb_angle = mix(-0.55 + sin(beat * 2.0) * 0.12 * throw,
				-2.9, hands_up * 0.6);
			body_lower = abs(sin(beat)) * 0.03 * throw * m_hype;
			sway = sin(beat) * 0.045 * throw;
			head_nod = sin(beat * 2.0) * 0.12;
			yaw_twist = sin(beat * 0.35) * 0.2;
		} else if (pose == POSE_RAVE) {
			// The bass stage: the dance thrown harder and faster — a bigger
			// hop, arms pumping high, more sway. Distinct from a fire circle
			// at any distance.
			float beat = on_beat ? mbeat : fx_time_npc * 3.6 * tempo + seed * 6.283;
			if (part == 2.0 || part == 3.0) limb_angle = mix(-2.7 + sin(beat * 2.0) * 0.55 * throw * m_hype,
				-3.0 + sin(beat * 4.0) * 0.06, hands_up);
			body_lower = -abs(sin(beat)) * 0.16 * throw * m_hype;
			sway = sin(beat) * 0.09 * throw;
		} else if (pose == POSE_WORK) {
			body_tilt = -0.55;                      // bent over the job
			if (part == 2.0 || part == 3.0) limb_angle = -0.75 + sin(fx_time_npc * 2.0 + seed * 6.283) * 0.25;
		} else if (pose == POSE_QUEUE) {
			sway = sin(fx_time_npc * 0.6 + seed * 6.283) * 0.03;
		} else if (pose == POSE_CHEER) {
			// Arms straight up, waving, a little hop: the effigy coming down,
			// the set's closer.
			float beat = fx_time_npc * 2.2 * tempo + seed * 6.283;
			if (part == 2.0) limb_angle = -2.95 + sin(beat * 1.7) * 0.22;
			else if (part == 3.0) limb_angle = -2.95 + sin(beat * 1.7 + 1.9) * 0.22;
			body_lower = -abs(sin(beat)) * 0.12 * throw;
		} else if (pose == POSE_DJ) {
			// At the decks: hands forward at waist height, the right working
			// the mixer, the left now and then thrown up (or to the
			// headphones); a steady head-nod bounce on the beat.
			// On the music: the nod is the beat; through the run-up to a
			// drop the left arm goes UP and HOLDS (the whole crowd watches
			// for it), the last moment and the drop itself both arms, and
			// the drop is a jump.
			float beat = on_beat ? mus.x * PI : fx_time_npc * 2.0 + seed * 6.283;
			float lift = smoothstep(0.7, 0.95, sin(fx_time_npc * 0.45 + seed * 17.0));
			float both = 0.0;
			if (on_beat) {
				lift = max(lift * (1.0 - smoothstep(0.0, 0.1, mus.w)), smoothstep(0.0, 0.12, mus.w));
				both = clamp(smoothstep(0.85, 1.0, mus.w) + mus.z * 1.5, 0.0, 1.0);
			}
			if (part == 3.0) limb_angle = mix(-0.95 + sin(beat * 2.0) * 0.12, -2.9, both);
			else if (part == 2.0) limb_angle = mix(-0.95 + sin(beat) * 0.08, -2.8, max(lift, both));
			body_lower = -abs(sin(beat)) * 0.05 * (1.0 + 3.0 * (on_beat ? mus.z : 0.0));
			sway = sin(beat * 0.5) * 0.025;
		} else if (pose == POSE_PEAK) {
			// FUCK YES!!! — the samba: the only dance whose FEET work (quick
			// alternating steps), hips swaying wide with the body twisting
			// against them, arms bent at chest height rolling opposite each
			// other, a light double-time bounce. Nothing like the rave's arms
			// overhead, at any distance.
			float beat = on_beat ? mbeat : fx_time_npc * 4.2 * tempo + seed * 6.283;
			float stp = sin(beat);
			if (part == 4.0) limb_angle = -max(stp, 0.0) * 0.45 + min(stp, 0.0) * 0.12;
			else if (part == 5.0) limb_angle = -max(-stp, 0.0) * 0.45 + min(-stp, 0.0) * 0.12;
			else if (part == 2.0) limb_angle = -1.15 - sin(beat) * 0.40 * throw;
			else if (part == 3.0) limb_angle = -1.15 + sin(beat) * 0.40 * throw;
			body_lower = abs(sin(beat * 2.0)) * 0.05;
			sway = sin(beat) * 0.11 * throw;
			yaw_twist = sin(beat) * 0.42 * throw;
		} else if (pose == POSE_TALK) {
			// A conversation circle: people take TURNS — each person's speaking
			// gate is a slow per-seed wave, so at any moment a few in a circle
			// gesture (one hand forward, beating out the point) while the rest
			// listen, shifting their weight. Reads as talk from the settlement
			// view's block height, and costs one sin() more than standing.
			// Turns come round often (speaking about 45 % of the time), the
			// speaker uses both hands, listeners NOD and now and then the
			// whole circle laughs (a bounce), and everyone shifts their weight
			// and glances about — a conversation, not a still ring.
			float turn = smoothstep(0.1, 0.5, sin(fx_time_npc * 0.32 * tempo + seed * 41.0));
			float beat = sin(fx_time_npc * 3.1 * tempo + seed * 6.283);
			float beat2 = sin(fx_time_npc * 2.3 * tempo + seed * 17.0);
			if (part == 3.0) limb_angle = -turn * (0.85 + 0.3 * beat) * throw;
			else if (part == 2.0) limb_angle = -turn * (0.35 + 0.35 * beat2) * throw;
			float laugh = smoothstep(0.9, 1.0, sin(fx_time_npc * 0.21 + seed * 9.0));
			body_lower = -abs(sin(fx_time_npc * 7.0)) * 0.03 * laugh;
			head_nod = (1.0 - turn) * max(sin(fx_time_npc * 1.7 * tempo + seed * 5.0), 0.0) * 0.28
				- laugh * 0.25;
			sway = sin(fx_time_npc * 0.5 * tempo + seed * 6.283) * 0.04;
			yaw_twist = sin(fx_time_npc * 0.27 * tempo + seed * 13.0) * 0.3;
		} else if (pose == POSE_STAND) {
			// Standing is never still: a slow weight shift from foot to foot,
			// a glance round now and then, arms easing with the sway — a
			// person waiting or watching, not a mannequin.
			float shift = sin(fx_time_npc * 0.55 * tempo + seed * 6.283);
			sway = shift * 0.045;
			body_lower = abs(shift) * 0.012;
			if (part == 2.0) limb_angle = 0.08 * shift;
			else if (part == 3.0) limb_angle = -0.08 * shift;
			else if (part == 4.0) limb_angle = max(shift, 0.0) * 0.1;
			else if (part == 5.0) limb_angle = max(-shift, 0.0) * 0.1;
			yaw_twist = sin(fx_time_npc * 0.23 * tempo + seed * 11.0) * 0.45;
			head_nod = sin(fx_time_npc * 0.4 * tempo + seed * 3.0) * 0.08;
		}
		if (part >= 2.0 && (abs(limb_angle) > 0.0001 || abs(limb_splay) > 0.0001 || leg_scale != 1.0)) {
			vec3 lv = v - pivot;
			if (part >= 4.0 && leg_scale != 1.0) {
				lv.y *= leg_scale;
			}
			// Outward is -x for the left parts (2, 4), +x for the right.
			float out_sign = (part == 2.0 || part == 4.0) ? -1.0 : 1.0;
			mat3 r = rot_x(limb_angle) * rot_z(out_sign * limb_splay);
			v = pivot + r * lv;
			n = r * n;
		}
		if (part == 1.0 && abs(head_nod) > 0.0001) {
			// The head tips about the neck (a nod, a laugh thrown back).
			mat3 rh = rot_x(head_nod);
			v = PIVOT_NECK + rh * (v - PIVOT_NECK);
			n = rh * n;
		}
		if (abs(body_tilt) > 0.0001) {
			// Lying tilts the whole figure about the waist; working bends the
			// trunk, head and arms but leaves the legs standing.
			bool whole = pose == POSE_LIE;
			if (whole || part < 4.0) {
				mat3 r2 = rot_x(-body_tilt);
				v = PIVOT_WAIST + r2 * (v - PIVOT_WAIST);
				n = r2 * n;
			}
		}
		v.y -= body_lower;
		v.x += sway;
		mat3 ry = rot_y(yaw + yaw_twist);
		vec3 wp = p + ry * v;
		vec3 wn = ry * n;
		VERTEX = (VIEW_MATRIX * vec4(wp, 1.0)).xyz;
		NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
	}
}

void fragment() {
	if (v_fade < 0.999) {
		// 4x4 ordered dither: a dissolve an opaque pass can draw.
		const float BAYER[16] = float[16](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0,
			3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
		ivec2 q = ivec2(FRAGCOORD.xy) % 4;
		float th = (BAYER[q.y * 4 + q.x] + 0.5) / 16.0;
		if (th > v_fade) {
			discard;
		}
	}
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float rim = pow(1.0 - facing, rim_power);
	ALBEDO = body_color.rgb + v_tint * rim * rim_strength;
	EMISSION = v_tint * rim * rim_emission;
	// Catching it: a green OUTLINE on the black body, only as they near FUCK
	// YES (glow_ramp), beating DOUBLE-TIME to the peakers' pulse (one shared
	// clock), so a crowd catching it visibly falls into time with the people
	// who have it; the last stretch sparkles.
	float bz = glow_ramp(v_buzz) * (1.0 - v_peak);
	if (bz > 0.002) {
		float beat = 0.5 + 0.5 * sin(fx_time_npc * 3.2);
		float spark = smoothstep(0.85, 1.0, v_buzz) * (0.5 + 0.5 * sin(fx_time_npc * 13.0 + v_seed * 40.0));
		EMISSION += PEAK_GREEN * bz * pow(rim, 0.6) * 1.5 * (0.35 + 0.65 * beat + 0.8 * spark);
	}
	// FUCK YES!: green, breathing on the cosmetic clock (frozen on pause) —
	// every peaker on the same breath — plus the ignition flash. By DAY the
	// body stays dark with a green outline and a dim inner glow (a flat green
	// figure in sunlight read as a coloured mannequin); at night the whole
	// body lights.
	if (v_peak > 0.0 || v_flash > 0.0) {
		float pulse = 0.72 + 0.28 * sin(fx_time_npc * 1.6);
		ALBEDO = mix(ALBEDO, PEAK_GREEN * 0.3, v_peak * 0.8 * npc_night);
		EMISSION += PEAK_GREEN * (v_peak * pulse * (mix(0.03, 1.0, npc_night) + mix(1.1, 1.4, npc_night) * rim) + v_flash * 2.2);
	}
	float part = v_glow_part;
	bool band = v_glow_style >= 0.0 && (
		((part > 1.5 && part < 3.5) && v_glow_frac > 0.78 && v_glow_frac < 0.88)
		|| (v_glow_style > 0.45 && part < 0.5 && v_glow_y > 1.42 && v_glow_y < 1.48)
		|| (v_glow_style > 0.8 && part > 0.5 && part < 1.5 && v_glow_y > 1.59 && v_glow_y < 1.64));
	if (band) {
		// By day a coloured plastic band; at night it glows (bloom carries it).
		ALBEDO = mix(ALBEDO, v_glow_col * 0.35, 0.8);
		EMISSION += v_glow_col * (0.05 + npc_night * 3.0);
	}
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.0;
}
