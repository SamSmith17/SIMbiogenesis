shader_type spatial;
// What a burned structure collapses into: a mound over its base footprint that
// starts as the bed of a bonfire and ages to cold ash. FireNode writes two
// numbers off FireNode.pile_look(): `heat` (1 = the whole bed glowing, falling
// through isolated red hot spots to 0 = dead black) and `ash` (0 = black char,
// 1 = grey-white ash). World-space noise, like fire_char / fire_ash, so the
// pattern does not stretch with the mound's non-uniform scale.
render_mode cull_disabled, specular_disabled;

// Cosmetic clock (SimFxRate): advances with the sim, time-lapsed and
// capped, frozen dead while paused. Replaces TIME, which never stops.
global uniform float fx_time_fire;

uniform float heat = 1.0;
uniform float ash = 0.0;

varying vec3 wpos;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(hash13(i), hash13(i + vec3(1, 0, 0)), f.x),
			mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), f.x),
			mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), f.x), f.y),
		f.z);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float coarse = vnoise(wpos * 2.6);
	float fine = vnoise(wpos * 9.0);
	float chunks = coarse * 0.65 + fine * 0.35;
	// UV.x is the radius (0 centre .. 1 rim): the middle of a fire bed stays hot
	// longest and the rim goes to ash first.
	float rim = UV.x * UV.x;

	vec3 char_col = mix(vec3(0.008, 0.007, 0.007), vec3(0.045, 0.040, 0.036), fine);
	vec3 ash_col = mix(vec3(0.30, 0.29, 0.28), vec3(0.80, 0.79, 0.76), chunks);
	// Flecks of unburned charcoal stay in it: ash is never one flat grey.
	ash_col *= mix(0.45, 1.0, smoothstep(0.22, 0.55, fine));
	float ashed = clamp(ash * 1.9 - chunks * 0.9 + rim * ash * 0.4, 0.0, 0.94);
	// Even a live ember bed carries a film of ash on its coolest lumps.
	float film = smoothstep(0.62, 0.9, chunks) * 0.18 * (1.0 - ash);
	ALBEDO = mix(char_col, ash_col, max(ashed, film));
	ROUGHNESS = 1.0;
	METALLIC = 0.0;

	// Glow: at full heat nearly everything is alight; as it cools the threshold
	// climbs and only the hot spots between the lumps are left.
	// (`chunks` is centred on 0.5: 0.40 lights about three quarters of the bed,
	// 0.63 a quarter of it — a bed of separate red coals, which is what embers are.)
	float thr = mix(0.86, 0.40, sqrt(heat)) + rim * 0.22 * (1.0 - heat * 0.6);
	float glow = smoothstep(thr, thr + 0.22, chunks + 0.12 * vnoise(wpos * 4.0 + vec3(0.0, fx_time_fire * 0.09, 0.0)));
	glow *= 0.72 + 0.28 * sin(fx_time_fire * 1.4 + fine * 14.0 + wpos.x * 2.0);  // embers breathe
	vec3 ember_col = mix(vec3(0.85, 0.06, 0.008), vec3(1.0, 0.42, 0.07), heat * heat);
	EMISSION = ember_col * glow * (0.7 + 1.5 * heat) * step(0.001, heat);
}
