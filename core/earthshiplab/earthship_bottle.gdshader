shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

// The glass of an Earthship bottle wall: the two bottle ends and the tube
// between them, set in a real hole through the plaster. COLOR is the glass
// colour (linear). BACKLIGHT carries the sun through from the other side, so
// a sunlit wall glows coloured indoors; a little emission keeps the ends
// readable in shade (light from the room bouncing in the glass).

uniform float glass_alpha : hint_range(0.0, 1.0) = 0.62;
uniform float glow : hint_range(0.0, 2.0) = 0.22;

void fragment() {
	ALBEDO = COLOR.rgb;
	ALPHA = glass_alpha;
	ROUGHNESS = 0.06;
	METALLIC = 0.0;
	SPECULAR = 0.65;
	BACKLIGHT = COLOR.rgb * 1.6;
	EMISSION = COLOR.rgb * glow;
}
