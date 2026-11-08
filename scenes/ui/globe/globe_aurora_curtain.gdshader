// Aurora curtains: one continuous sheet per oval (AuroraCurtains), leaning
// along dipole field lines from ~100 km to ~400 km. The vertex stage folds the
// sheet by the band's wander (aur_fold), so the curtain ripples in real time;
// the fragment lights it from the smooth band at the sheet's footpoint, with
// fine vertical rays, a sharp green lower edge and a red / purple top. Night
// side only; a sheet seen edge-on is a longer path through the glow. The
// faint shells stay behind.
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, fog_disabled;

#include "res://core/globe/aurora.gdshaderinc"

uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);
uniform float curtain_gain = 1.0;

varying vec3 w_pos;      // undisplaced position (globe frame, radii)
varying vec3 w_n;        // the sheet's horizontal normal (poleward)
varying float v_sheet;   // which sheet (fold phase)
varying float v_weight;  // the main sheet 1, the side sheets fainter

void vertex() {
	w_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	w_n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_sheet = COLOR.r * 6.2832;
	v_weight = COLOR.g < 0.1 ? 1.0 : 0.38;
	float r = length(w_pos);
	vec3 p = w_pos / max(r, 1e-4);
	vec2 mg = aur_mag_angles(p);
	// The fold moves the whole field line sideways, more at the top (the
	// line fans out as it rises).
	float hk = (r - 1.0) * 6371.0;
	float fold_deg = aur_fold(mg.x, TIME, v_sheet) * (1.0 + 0.6 * hk / 400.0);
	vec3 moved = normalize(p + w_n * radians(fold_deg)) * r;
	VERTEX = (inverse(MODEL_MATRIX) * vec4(moved, 1.0)).xyz;
}

void fragment() {
	float r = length(w_pos);
	vec3 p = w_pos / max(r, 1e-4);
	vec3 axis = normalize(aurora_pole);
	float hemi = dot(p, axis) >= 0.0 ? 1.0 : -1.0;
	axis *= hemi;
	float cos_t = clamp(dot(p, axis), -1.0, 1.0);
	float sin2 = max(1.0 - cos_t * cos_t, 1e-4);
	// Foot of the same field line, back at the green-line height.
	float r_foot = 1.0 + 100.0 / 6371.0;
	float sin2_f = clamp(r_foot * sin2 / r, 0.0, 1.0);
	float cos_f = sqrt(max(1.0 - sin2_f, 0.0));
	vec3 perp = p - axis * cos_t;
	float plen = length(perp);
	vec3 foot = plen < 1e-4 ? axis : (axis * cos_f + (perp / plen) * sqrt(sin2_f));
	float dark = 1.0 - smoothstep(-0.12, 0.04, dot(foot, normalize(sun_dir)));
	float s = aurora_on ? aurora_band(foot, TIME, 1.0) : 0.0;
	float hk = (r - 1.0) * 6371.0;
	// Height profile: nothing under ~95 km, the bright lower border at
	// 100-130 km, an exponential tail to the top of the sheet.
	float edge = smoothstep(92.0, 108.0, hk);
	float tail = exp(-max(hk - 115.0, 0.0) / 110.0);
	float body = edge * (0.25 + 0.75 * tail) * smoothstep(420.0, 330.0, hk);
	// Rays reach higher where the band is strong (a storm's tall curtains).
	body *= mix(1.0, 1.4, smoothstep(0.6, 1.4, s) * smoothstep(130.0, 260.0, hk));
	// The red line is a faint veil over the green border, never a second band.
	float red_k = smoothstep(140.0, 260.0, hk);
	vec3 col = mix(AUR_GREEN, AUR_RED * 0.55, red_k);
	body *= mix(1.0, 0.55, red_k);
	// A storm's purple-pink fringe just under the green border.
	col = mix(col, AUR_FRINGE, (1.0 - smoothstep(100.0, 120.0, hk)) * smoothstep(5.0, 8.5, aurora_kp) * 0.5);
	// Edge-on sheets are brighter: a longer path through the glowing layer.
	vec3 v = normalize(CAMERA_POSITION_WORLD - w_pos);
	float path = clamp(1.0 / max(abs(dot(normalize(w_n), v)), 0.3), 1.0, 2.6);
	float e = 1.0 - exp(-1.5 * clamp(s, 0.0, 3.0));
	ALBEDO = col * e * dark * body * path * 0.95 * v_weight * curtain_gain;
}
