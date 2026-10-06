shader_type spatial;
// Bulbs of a J-placed string light (PlacedStringLight), one MultiMesh per
// string. Each instance carries INSTANCE_CUSTOM = (bulb index, bulb count,
// seed, 0); the effect block (led_effects.gdshaderinc) is a LINE-FOR-LINE MIRROR of
// LedEffects.color_at (core/placed_lights/led_effects.gd) — the string's real
// OmniLights call that function at their own bulb indices with the SAME
// `fx_time` this material is given, so the light cast on the ground chases
// along with the bulbs. Edit both; placed_lights_selftest pins the constants.
//
// Opaque and depth-tested on purpose: a bulb behind a tent is hidden by it.
// (Conduit light kinds draw through walls — that is the x-ray conduit rule, not
// a look a festoon on a pergola should have.)
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://gameplay/led_effects.gdshaderinc"

// energy × on/off (0 by day / switched off / unpowered).
uniform float glow = 0.0;
// Bulb glass when dark: a hint of the bulb's colour on clear glass.
uniform float glass_tint = 0.35;

varying flat vec2 v_bulb;

void vertex() {
	v_bulb = INSTANCE_CUSTOM.rg;
}

void fragment() {
	vec3 c = led_color(v_bulb.x, v_bulb.y, fx_time);
	ALBEDO = mix(vec3(0.85), c, glass_tint) * 0.6;
	ROUGHNESS = 0.18;
	SPECULAR = 0.6;
	EMISSION = c * glow;
}
