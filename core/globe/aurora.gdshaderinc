// The aurora, shared by the globe's aurora shells and the ground sky.
// MIRROR of core/globe/aurora_model.gd (AuroraModel): the constants below
// must match it, and globe_selftest reads them out of this file. Directions
// are unit vectors in the globe frame (GlobeMath: +Y north, lon 0 on +Z,
// 90° E on +X).

const float AUR_EQ_MID0 = 66.0;
const float AUR_EQ_PER_KP = 2.2;
const float AUR_EQ_NOON = 9.0;
const float AUR_WIDTH0 = 4.0;
const float AUR_WIDTH_PER_KP = 0.6;
const float AUR_OVATION_FULL = 30.0;
// OVATION reports a few % almost everywhere near the poles; below this the
// aurora is not visible.
const float AUR_OVATION_MIN = 5.0;

uniform bool aurora_on = false;
uniform float aurora_kp = 2.0;
uniform vec3 aurora_pole = vec3(0.0, 1.0, 0.0);
uniform vec3 aurora_sun = vec3(1.0, 0.0, 0.0);
// NOAA SWPC OVATION nowcast (probability %, 360 x 181, x = longitude 0..359
// east, y = 90 - latitude), used instead of the Kp oval near the present.
uniform bool aurora_use_ovation = false;
uniform sampler2D aurora_ovation : filter_linear, repeat_enable;
uniform float aurora_gain = 1.0;

float aur_hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float aur_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(aur_hash(i), aur_hash(i + vec2(1.0, 0.0)), u.x),
		mix(aur_hash(i + vec2(0.0, 1.0)), aur_hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

// [angle round the dipole axis (radians), angle from magnetic midnight].
vec2 aur_mag_angles(vec3 p) {
	vec3 a = p - aurora_pole * dot(p, aurora_pole);
	vec3 s = aurora_sun - aurora_pole * dot(aurora_sun, aurora_pole);
	vec3 ref = normalize(cross(aurora_pole, vec3(0.0, 0.0, 1.0)));
	vec3 ref2 = cross(aurora_pole, ref);
	float lon = atan(dot(a, ref2), dot(a, ref));
	float c = clamp(dot(normalize(a + 1e-6), normalize(s + 1e-6)), -1.0, 1.0);
	return vec2(lon, PI - acos(c));
}

float aur_model(vec3 p, float fold) {
	float ml = abs(degrees(asin(clamp(dot(p, aurora_pole), -1.0, 1.0)))) + fold;
	float phi = aur_mag_angles(p).y;
	float w = (AUR_WIDTH0 + AUR_WIDTH_PER_KP * aurora_kp) * (0.55 + 0.45 * cos(phi));
	float c = AUR_EQ_MID0 - AUR_EQ_PER_KP * aurora_kp + AUR_EQ_NOON * 0.5 * (1.0 - cos(phi)) + 0.5 * w;
	float x = (ml - c) / (0.5 * w);
	float bright = clamp((aurora_kp + 0.5) / 5.0, 0.15, 1.6) * (0.55 + 0.45 * cos(phi));
	return bright * exp(-2.0 * x * x);
}

float aur_ovation(vec3 p) {
	float lat = degrees(asin(clamp(p.y, -1.0, 1.0)));
	float lon = degrees(atan(p.x, p.z));
	vec2 uv = vec2((mod(lon, 360.0) + 0.5) / 360.0, (90.0 - lat + 0.5) / 181.0);
	float pc = textureLod(aurora_ovation, uv, 0.0).r * 100.0;
	return max(pc - AUR_OVATION_MIN, 0.0) / (AUR_OVATION_FULL - AUR_OVATION_MIN);
}

// The aurora's brightness at a point of the sky's emission layer, with the
// curtains: folds that wander along the oval (a wavy band, slowly moving) and
// fine rays along magnetic longitude, both on real time `t` (seconds).
float aurora_at(vec3 p, float t) {
	vec2 mg = aur_mag_angles(p);
	float fold = 1.4 * sin(mg.x * 7.0 + t * 0.021) + 0.8 * sin(mg.x * 17.0 - t * 0.037);
	float s = aurora_use_ovation ? aur_ovation(normalize(p + vec3(0.0, fold * 0.0035, 0.0))) : aur_model(p, fold);
	float rays = aur_noise(vec2(mg.x * 260.0 + t * 0.05, t * 0.02));
	rays = mix(0.35, 1.0, rays * rays);
	float shimmer = 0.85 + 0.15 * aur_noise(vec2(mg.x * 60.0 - t * 0.4, t * 0.3));
	return s * rays * shimmer * aurora_gain;
}

// The band's fold at a magnetic longitude (degrees of latitude), the same
// wander aurora_at folds into the model. The curtain mesh moves its geometry
// by it (vertex stage) and then reads the smooth band at the undisplaced
// foot, so the sheet ripples without the brightness sliding off it.
float aur_fold(float mag_lon, float t, float phase) {
	return 0.8 * sin(mag_lon * 7.0 + t * 0.021 + phase) + 0.45 * sin(mag_lon * 17.0 - t * 0.037 + phase * 1.7)
		+ 0.22 * sin(mag_lon * 41.0 + t * 0.09 + phase * 2.3);
}

// The smooth band (no fold) with the fine rays: what a curtain sheet is lit
// by at its footpoint. `ray_detail` sharpens the rays (1 = the shell's).
float aurora_band(vec3 p, float t, float ray_detail) {
	vec2 mg = aur_mag_angles(p);
	float s = aurora_use_ovation ? aur_ovation(p) : aur_model(p, 0.0);
	float r1 = aur_noise(vec2(mg.x * 260.0 + t * 0.05, t * 0.02));
	float r2 = aur_noise(vec2(mg.x * 900.0 - t * 0.11, t * 0.07));
	float rays = mix(0.3, 1.0, r1 * r1) * mix(1.0 - 0.55 * ray_detail, 1.0, r2);
	float shimmer = 0.85 + 0.15 * aur_noise(vec2(mg.x * 60.0 - t * 0.4, t * 0.3));
	return s * rays * shimmer * aurora_gain;
}

// Emission colours: the 557.7 nm green line low down, the 630 nm red line
// above ~200 km, a purple-pink fringe (N2) under strong aurora.
// (Linear colour: a little red or blue here turns grey once it is dim.)
const vec3 AUR_GREEN = vec3(0.05, 1.00, 0.26);
const vec3 AUR_RED = vec3(1.00, 0.06, 0.14);
const vec3 AUR_FRINGE = vec3(0.55, 0.08, 0.80);

// --- From the ground (the sky shader) ---------------------------------------
// The site and its local east / north in the globe frame, and how bright the
// aurora is drawn in the sky.
uniform vec3 aurora_site = vec3(0.0, 1.0, 0.0);
uniform vec3 aurora_east = vec3(1.0, 0.0, 0.0);
uniform vec3 aurora_north = vec3(0.0, 0.0, -1.0);
uniform float aurora_sky_gain = 0.12;

// What a sky direction `eye` (world: +Y up, north = -Z, east = +X) sees of
// the aurora: the ray is followed to three emission heights (105, 150 and
// 230 km), each the point on the globe below it, so a curtain hundreds of km
// away stands low over the horizon and one overhead fills the sky.
vec3 aurora_sky(vec3 eye, float t) {
	if (!aurora_on || eye.y <= 0.0) {
		return vec3(0.0);
	}
	vec3 h = normalize(vec3(eye.x, 0.0, eye.z) + vec3(1e-5, 0.0, 0.0));
	vec3 dir = aurora_north * (-h.z) + aurora_east * h.x;
	float e = asin(clamp(eye.y, 0.0, 1.0));
	vec3 col = vec3(0.0);
	for (int i = 0; i < 3; i++) {
		float hk = i == 0 ? 105.0 : (i == 1 ? 150.0 : 230.0);
		float g = acos(clamp(6371.0 * cos(e) / (6371.0 + hk), -1.0, 1.0)) - e;
		vec3 p = normalize(aurora_site * cos(g) + dir * sin(g));
		float s = aurora_at(p, t);
		vec3 c = i == 0 ? mix(AUR_GREEN, AUR_FRINGE, 0.18 * smoothstep(5.5, 8.5, aurora_kp))
			: (i == 1 ? AUR_GREEN : AUR_RED);
		col += c * s * (i == 0 ? 0.7 : (i == 1 ? 0.5 : 0.18));
	}
	// A longer path through the glowing layer toward the horizon; the lowest
	// degrees fade into the haze.
	float path = inversesqrt(max(eye.y, 0.06));
	return col * path * smoothstep(0.0, 0.05, eye.y) * aurora_sky_gain;
}
