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

uniform float t_rel = 0.0;           // sim hours since CrowdRenderer.time_base
uniform float figure_dist = 150.0;   // metres: beyond this the card draws instead
uniform float lod_dist = 0.0;        // > 0: nothing draws beyond this (the "lod" pref)
uniform float draw_mode = 1.0;       // 0 = hide everything
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

// Pose codes (CrowdCohort.pose_code).
const float POSE_STAND = 0.0;
const float POSE_WALK = 1.0;
const float POSE_SIT = 2.0;
const float POSE_LIE = 3.0;
const float POSE_DANCE = 4.0;
const float POSE_WORK = 5.0;
const float POSE_QUEUE = 6.0;
const float POSE_RAVE = 7.0;

varying vec3 v_tint;

mat3 rot_x(float a) {
	float c = cos(a);
	float s = sin(a);
	return mat3(vec3(1.0, 0.0, 0.0), vec3(0.0, c, s), vec3(0.0, -s, c));
}

mat3 rot_y(float a) {
	float c = cos(a);
	float s = sin(a);
	return mat3(vec3(c, 0.0, -s), vec3(0.0, 1.0, 0.0), vec3(s, 0.0, c));
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
	v_tint = COLOR.rgb;

	float span = max(t1 - t0, 1e-6);
	float u = clamp((t_rel - t0) / span, 0.0, 1.0);
	vec3 p = mix(a, b, u);
	if (height_ready > 0.5) {
		vec2 huv = (p.xz - height_rect.xy) / max(height_rect.zw, vec2(1e-3));
		if (huv.x >= 0.0 && huv.x <= 1.0 && huv.y >= 0.0 && huv.y <= 1.0) {
			p.y = textureLod(height_tex, huv, 0.0).r;
		}
	}
	vec3 seg = b - a;
	float seg_len = length(seg.xz);
	float dist = distance(p, CAMERA_POSITION_WORLD);
	bool hidden = flags >= 1.0 || draw_mode < 0.5 || dist > figure_dist
		|| (lod_dist > 0.0 && dist > lod_dist);
	if (hidden) {
		VERTEX = vec3(0.0, 0.0, 1.0);   // behind the camera in view space: clipped
		NORMAL = vec3(0.0, 0.0, 1.0);
	} else {
		// Standing people do not all face their anchor dead-on: a per-person
		// stance offset of up to ±25°. Walkers face where they are going.
		float yaw = seg_len > 0.05 ? atan(seg.x, seg.z) : yaw_hint + (seed - 0.5) * 0.9;
		bool walking = pose == POSE_WALK && u < 1.0 && seg_len > 0.05;
		// Per-person tempo and throw, so a crowd is not a chorus line.
		float tempo = 0.8 + seed * 0.45;
		float throw = 0.75 + fract(seed * 7.31) * 0.5;
		float part = floor(UV2.x * 5.0 + 0.5);
		float frac = UV2.y;
		vec3 v = VERTEX;
		vec3 n = NORMAL;
		float sway = sin(TIME * 0.9 * tempo + seed * 6.283) * 0.02 * throw;
		float limb_angle = 0.0;
		vec3 pivot = PIVOT_WAIST;
		if (part == 2.0) { pivot = PIVOT_SHOULDER_L; }
		else if (part == 3.0) { pivot = PIVOT_SHOULDER_R; }
		else if (part == 4.0) { pivot = PIVOT_HIP_L; }
		else if (part == 5.0) { pivot = PIVOT_HIP_R; }
		float body_lower = 0.0;
		float body_tilt = 0.0;
		if (walking) {
			float ph = (u * seg_len / max(stride_m, 0.1)) * 6.283 + seed * 6.283;
			float swing = sin(ph) * 0.55;
			if (part == 4.0) limb_angle = swing;
			else if (part == 5.0) limb_angle = -swing;
			else if (part == 2.0) limb_angle = -swing * 0.7;
			else if (part == 3.0) limb_angle = swing * 0.7;
			body_lower = -abs(sin(ph)) * 0.03;
		} else if (pose == POSE_SIT) {
			if (part >= 4.0) limb_angle = 1.35;   // thighs forward, as a bench
			body_lower = 0.42;
		} else if (pose == POSE_LIE) {
			body_tilt = 1.5;                       // laid back on the ground
			body_lower = 0.78;
		} else if (pose == POSE_DANCE) {
			float beat = TIME * 2.6 * tempo + seed * 6.283;
			if (part == 2.0 || part == 3.0) limb_angle = -2.5 + sin(beat * 2.0) * 0.3 * throw;
			body_lower = -abs(sin(beat)) * 0.08 * throw;
			sway = sin(beat) * 0.05 * throw;
		} else if (pose == POSE_RAVE) {
			// The bass stage: the dance thrown harder and faster — a bigger
			// hop, arms pumping high, more sway. Distinct from a fire circle
			// at any distance.
			float beat = TIME * 3.6 * tempo + seed * 6.283;
			if (part == 2.0 || part == 3.0) limb_angle = -2.7 + sin(beat * 2.0) * 0.55 * throw;
			body_lower = -abs(sin(beat)) * 0.16 * throw;
			sway = sin(beat) * 0.09 * throw;
		} else if (pose == POSE_WORK) {
			body_tilt = 0.55;                       // bent over the job
			if (part == 2.0 || part == 3.0) limb_angle = 0.9 + sin(TIME * 2.0 + seed * 6.283) * 0.25;
		} else if (pose == POSE_QUEUE) {
			sway = sin(TIME * 0.6 + seed * 6.283) * 0.03;
		}
		if (part >= 2.0 && abs(limb_angle) > 0.0001) {
			mat3 r = rot_x(limb_angle);
			v = pivot + r * (v - pivot);
			n = r * n;
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
		mat3 ry = rot_y(yaw);
		vec3 wp = p + ry * v;
		vec3 wn = ry * n;
		VERTEX = (VIEW_MATRIX * vec4(wp, 1.0)).xyz;
		NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
	}
}

void fragment() {
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float rim = pow(1.0 - facing, rim_power);
	ALBEDO = body_color.rgb + v_tint * rim * rim_strength;
	EMISSION = v_tint * rim * rim_emission;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.0;
}
