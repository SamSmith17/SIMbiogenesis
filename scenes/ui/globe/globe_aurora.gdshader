// The aurora on the globe: two additive shells, the green line at ~110 km
// (shell 0, r 1.0173) and the red line at ~230 km (shell 1, r 1.036), lit
// only on the night side. The oval / OVATION nowcast and the curtains come
// from core/globe/aurora.gdshaderinc, shared with the ground sky.
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, fog_disabled;

#include "res://core/globe/aurora.gdshaderinc"

uniform int shell = 0;
uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);

varying vec3 w_pos;

void vertex() {
	w_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 p = normalize(w_pos);
	float dark = 1.0 - smoothstep(-0.12, 0.04, dot(p, normalize(sun_dir)));
	float s = aurora_on ? aurora_at(p, TIME) : 0.0;
	// A curtain seen edge-on (near the limb, or from low down) is a longer
	// path through the glowing layer.
	vec3 v = normalize(CAMERA_POSITION_WORLD - w_pos);
	float path = 1.0 / max(abs(dot(p, v)), 0.35);
	vec3 col = shell == 0 ? mix(AUR_GREEN, AUR_FRINGE, smoothstep(5.5, 8.5, aurora_kp) * 0.35) : AUR_RED;
	float k = shell == 0 ? 0.14 : 0.03;
	// Saturating, so a Kp 9 night stays green rather than burning to white.
	float e = 1.0 - exp(-1.4 * clamp(s, 0.0, 3.0));
	ALBEDO = col * e * dark * path * k;
}
