// Addressable-LED effects for J lights — the GPU half, shared by the bulbs
// (led_bulb.gdshader) and the continuous tubes (led_rope.gdshader: rope
// light, LED neon flex, glass neon, EL wire).
//
// led_color() is a LINE-FOR-LINE MIRROR of LedEffects.color_at
// (core/placed_lights/led_effects.gd). The string's real OmniLights call the
// GDScript one at their own pixel indices with the SAME `fx_time` (the shared
// PlacedLightClock), so the light thrown on the ground chases with the LEDs.
// Edit both; placed_lights_selftest parses the constants out of this file.

uniform int fx_mode = 0;
uniform float fx_speed = 6.0;
uniform float fx_span = 24.0;
uniform float fx_gap = 3.0;
uniform float fx_saturation = 1.0;
uniform float fx_direction = 1.0;
uniform float fx_time = 0.0;
uniform vec3 base_color : source_color = vec3(1.0, 0.82, 0.55);

const float TWINKLE_FLOOR = 0.18;
const float BREATHE_FLOOR = 0.12;
const float CHASE_DIM = 0.06;
const float WIPE_HUE_STEP = 0.17;
const float BREATHE_BULBS = 16.0;
const float FLICKER_FLOOR = 0.35;
const float STROBE_DUTY = 0.12;

// HSV -> sRGB -> linear. Color.from_hsv on the CPU yields an sRGB colour that
// Godot linearises for the OmniLight; base_color arrives linearised through
// source_color. Without this the rainbow's LEDs and the light they cast would
// not be the same colour.
vec3 hsv2rgb(vec3 c) {
	vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
	vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
	vec3 srgb = c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
	return mix(srgb / 12.92, pow((srgb + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), srgb));
}

float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

vec3 led_color(float fi, float n, float t) {
	float speed = fx_speed;
	float span = max(fx_span, 1.0);
	float gap = max(round(fx_gap), 2.0);
	float sat = clamp(fx_saturation, 0.0, 1.0);
	float dir = fx_direction < 0.0 ? -1.0 : 1.0;
	float x = fi * dir;
	if (fx_mode == 1) {
		float h = fract((x - speed * t) / span);
		return hsv2rgb(vec3(h, sat, 1.0));
	} else if (fx_mode == 2) {
		float k = mod(x - floor(speed * t), gap);
		return k < 1.0 ? base_color : base_color * CHASE_DIM;
	} else if (fx_mode == 3) {
		float r1 = hash11(fi + 0.5);
		float r2 = hash11(fi * 1.7 + 11.3);
		float w = 0.5 + 0.5 * sin(t * speed * (0.35 + r2) + r1 * 6.28318530718);
		return base_color * (TWINKLE_FLOOR + (1.0 - TWINKLE_FLOOR) * w * w * w);
	} else if (fx_mode == 4) {
		float b = 0.5 - 0.5 * cos(6.28318530718 * t * speed / BREATHE_BULBS);
		return base_color * (BREATHE_FLOOR + (1.0 - BREATHE_FLOOR) * b);
	} else if (fx_mode == 5) {
		float nn = max(n, 1.0);
		float head = speed * t;
		float cycle = floor(head / nn);
		float pos = head - cycle * nn;
		float idx = dir > 0.0 ? x : nn - 1.0 + x;
		float c = idx < pos ? cycle : cycle - 1.0;
		return hsv2rgb(vec3(fract(c * WIPE_HUE_STEP), sat, 1.0));
	} else if (fx_mode == 6) {
		float r1 = hash11(fi + 0.5);
		float r2 = hash11(fi * 1.7 + 11.3);
		float w = 0.55 + 0.22 * sin(t * speed * 1.3 + r1 * 6.28318530718)
			+ 0.15 * sin(t * speed * 3.1 + r2 * 6.28318530718)
			+ 0.08 * sin(t * speed * 7.7 + r1 * 17.0);
		return base_color * (FLICKER_FLOOR + (1.0 - FLICKER_FLOOR) * clamp(w, 0.0, 1.0));
	} else if (fx_mode == 7) {
		return fract(t * speed) < STROBE_DUTY ? base_color : vec3(0.0);
	}
	return base_color;
}
