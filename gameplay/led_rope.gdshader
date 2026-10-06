shader_type spatial;
// A CONTINUOUS light tube — LED rope light, LED neon flex, glass neon, EL wire
// (PlacedStringLight with a `continuous` preset). The tube mesh carries its
// arc length in UV.x (metres from the first pin), so pixel i sits at
// i / leds_per_m along it, and the SAME effect function the bulbs use
// (led_effects.gdshaderinc, mirrored by LedEffects.color_at) colours it.
// Between pixels the colour is blended — the diffuser is what turns a row of
// LEDs into one even line of light, which is the whole look of neon flex.
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

#include "res://gameplay/led_effects.gdshaderinc"

uniform float leds_per_m = 36.0;
uniform float total_px = 100.0;
// energy × on/off (0 by day / off / unpowered).
uniform float glow = 0.0;
// How much of the colour the jacket shows unlit (milky diffuser vs clear).
uniform float jacket_tint = 0.3;

void fragment() {
	float px = UV.x * leds_per_m;
	float i0 = floor(px);
	vec3 c0 = led_color(i0, total_px, fx_time);
	vec3 c1 = led_color(i0 + 1.0, total_px, fx_time);
	vec3 c = mix(c0, c1, smoothstep(0.0, 1.0, px - i0));
	// Brighter where the jacket faces the viewer: the diffuser's front face.
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	ALBEDO = mix(vec3(0.82), base_color, jacket_tint) * 0.45;
	ROUGHNESS = 0.35;
	EMISSION = c * glow * (0.65 + 0.35 * facing);
}
