shader_type spatial;
// Glow sticks / EL wire on a full-tier figure (NpcSimpleFigure): wristbands,
// a necklace, sometimes a headband. By day a coloured plastic band; at night
// `npc_night` (Main, DaylightModel.night_amount) lifts it into HDR so the
// glow pass blooms it. Same carrier rule and palette as crowd_figure.gdshader
// so a person keeps their colour when they move between the two renderers.
render_mode unshaded, cull_disabled, shadows_disabled;

global uniform float npc_night;
instance uniform vec3 glow_col = vec3(0.25, 1.0, 0.35);

void fragment() {
	ALBEDO = glow_col * (0.35 + npc_night * 2.2);
}
