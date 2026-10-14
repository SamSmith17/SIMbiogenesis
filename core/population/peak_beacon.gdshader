shader_type spatial;
// PEAK BEACON: a column of green light standing over someone who just hit
// FUCK YES!!! (PeakBeacon). A unit cylinder scaled to the beam; UV.y runs
// top (0) to bottom (1). Brightest at the foot, fading up into the sky; a
// band of light climbs the column so it reads as alive; the edges soften
// (fresnel) so it is a glow, not a pipe. Additive, unshaded, fog_disabled
// (Godot fogs additive geometry into a coloured slab by day).
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

uniform vec3 beam_color : source_color = vec3(0.35, 1.0, 0.45);
uniform float fade = 1.0;
uniform float t = 0.0;

void fragment() {
	float up = 1.0 - UV.y;                       // 0 at the foot, 1 at the top
	float foot = exp(-up * 3.2) * 0.8 + 0.2 * (1.0 - up);
	float climb = smoothstep(0.08, 0.0, abs(fract(up * 1.2 - t * 0.7) - 0.5) - 0.35);
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float core = pow(facing, 1.6);
	float a = (foot + climb * 0.35 * (1.0 - up)) * core * fade;
	ALBEDO = beam_color * a * 2.2;
	ALPHA = clamp(a, 0.0, 1.0);
}
