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

void fragment() {
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float rim = pow(1.0 - facing, rim_power);
	ALBEDO = body_color.rgb + rim_color.rgb * rim * rim_strength;
	EMISSION = rim_color.rgb * rim * rim_emission;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	SPECULAR = 0.0;
}
