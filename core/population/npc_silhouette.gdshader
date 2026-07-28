shader_type spatial;
// Indistinct silhouette shading for NPC figures.
//
// Deliberately `unshaded`: a lit character reads as a *person* (you start
// looking at the face), while a flat dark mass reads as *someone* — which is
// what the population sim wants. Unshaded also keeps the figures legible at
// every hour of the sim day instead of dissolving into a night scene or
// blowing out at noon.
//
// Identity survives via a fresnel rim tinted with the agent's stable pastel —
// the same colour the Site Plan dots and morale tinting already use — so a
// crowd stays countable and individuals stay tellable apart without ever
// resolving into detail. The rim doubles as the "blurred edge": grazing
// angles wash out, so the outline reads soft rather than cut-out.
render_mode unshaded, cull_back, depth_draw_opaque, shadows_disabled;

uniform vec4 body_color : source_color = vec4(0.022, 0.026, 0.038, 1.0);
uniform vec4 rim_color : source_color = vec4(0.55, 0.62, 0.78, 1.0);
// A body is mostly limbs, and a cylinder shows grazing angles across most of
// its visible surface — so a soft fresnel that looks like a thin edge on a
// sphere floods an entire human figure with colour. The exponent has to be
// high enough to keep the tint on the true outline.
uniform float rim_power : hint_range(0.5, 16.0) = 6.5;
uniform float rim_strength : hint_range(0.0, 2.0) = 0.85;
// Lifts the whole figure a touch so it never becomes a true black hole against
// a dark night ground; kept small so daytime still reads as a silhouette.
uniform float floor_lift : hint_range(0.0, 0.3) = 0.018;

void fragment() {
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float rim = pow(1.0 - facing, rim_power);
	ALBEDO = body_color.rgb + rim_color.rgb * rim * rim_strength + vec3(floor_lift);
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
}
