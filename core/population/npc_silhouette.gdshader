shader_type spatial;
// Indistinct silhouette shading for NPC figures.
//
// A near-black body reads as *someone* rather than as a person you are meant
// to look at, and identity survives via a fresnel rim tinted with the agent's
// stable pastel — the same colour the Site Plan dots and morale tinting use —
// so a crowd stays countable without anyone resolving into detail. The rim
// doubles as the "blurred edge": grazing angles wash out, so the outline reads
// soft rather than cut-out.
//
// This was `unshaded` at first, which was wrong. Unshaded ignores *lighting*
// but NOT *exposure*: the tonemapper still scales the result, so figures that
// looked correctly dark at noon turned into glowing white cut-outs at night,
// when the scene is dark and exposure is high. Being lit is what makes a
// silhouette track its background across the day/night cycle for free, with no
// time-of-day uniform to keep in sync.
//
// Only the rim carries a small emissive floor, so people stay readable in the
// dark as an outline — never as a lit-up body.
render_mode cull_back, diffuse_lambert, specular_schlick_ggx;

uniform vec4 body_color : source_color = vec4(0.022, 0.026, 0.038, 1.0);
uniform vec4 rim_color : source_color = vec4(0.55, 0.62, 0.78, 1.0);
// A body is mostly limbs, and a cylinder shows grazing angles across most of
// its visible surface — so a soft fresnel that looks like a thin edge on a
// sphere floods an entire human figure with colour. The exponent has to be
// high enough to keep the tint on the true outline.
uniform float rim_power : hint_range(0.5, 16.0) = 6.5;
uniform float rim_strength : hint_range(0.0, 2.0) = 0.85;
// Emissive floor on the RIM ONLY. Enough that an outline survives an unlit
// night, small enough to stay under the glow threshold so nobody blooms.
uniform float rim_emission : hint_range(0.0, 1.0) = 0.16;
// MOOD: how good a time this person is having (morale 0..1) glows softly in
// their own colour over the whole body; PEAK (0..1, eased by NpcAvatar) is
// FUCK YES! — green, breathing on the cosmetic clock — and peak_flash the
// brief ignition burst. The same maths as crowd_figure.gdshader, so a person
// looks the same in either renderer.
global uniform float fx_time_npc;
global uniform float npc_night;
uniform float mood : hint_range(0.0, 1.0) = 0.0;
uniform float peak : hint_range(0.0, 1.0) = 0.0;
uniform float peak_flash : hint_range(0.0, 1.0) = 0.0;
// How close to FUCK YES (0..1, eased by NpcAvatar from the NpcPeak buzz).
uniform float buzz : hint_range(0.0, 1.0) = 0.0;
uniform float pulse_seed = 0.0;
const vec3 PEAK_GREEN = vec3(0.35, 1.0, 0.45);
// One warm amber for the mood glow (never the identity pastel — see
// crowd_figure.gdshader): green means FUCK YES! and nothing else.
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

void fragment() {
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float rim = pow(1.0 - facing, rim_power);
	ALBEDO = body_color.rgb + rim_color.rgb * rim * rim_strength;
	EMISSION = rim_color.rgb * rim * rim_emission;
	// Catching it: a green OUTLINE on the black body, only near FUCK YES
	// (glow_ramp; see crowd_figure.gdshader — the same curve).
	float bz = glow_ramp(buzz) * (1.0 - peak);
	if (bz > 0.002) {
		float beat = 0.5 + 0.5 * sin(fx_time_npc * 3.2);
		float spark = smoothstep(0.85, 1.0, buzz) * (0.5 + 0.5 * sin(fx_time_npc * 13.0 + pulse_seed * 40.0));
		EMISSION += PEAK_GREEN * bz * pow(rim, 0.6) * 1.5 * (0.35 + 0.65 * beat + 0.8 * spark);
	}
	if (peak > 0.0 || peak_flash > 0.0) {
		float pulse = 0.72 + 0.28 * sin(fx_time_npc * 1.6);
		ALBEDO = mix(ALBEDO, PEAK_GREEN * 0.3, peak * 0.8 * npc_night);
		EMISSION += PEAK_GREEN * (peak * pulse * (mix(0.03, 1.0, npc_night) + mix(1.1, 1.4, npc_night) * rim) + peak_flash * 2.2);
	}
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.0;
}
