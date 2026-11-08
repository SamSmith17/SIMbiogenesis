// A line on the globe's sky or ground at a constant width in PIXELS, whatever
// the distance: the sun's analemma, the Moon's orbit, a planet's year, a
// ground track. The mesh (AnalemmaPaths.line_mesh) puts two vertices at each
// point, NORMAL = the path's tangent, UV.x = -1 / +1 for the two sides and
// UV.y = 0..1 along the path; the vertex stage pushes each side out across the
// view ray so the strip always faces the camera. Depth-tested against the
// globe (a path behind the Earth is hidden), no depth write.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, fog_disabled;

uniform vec4 color : source_color = vec4(1.0, 0.8, 0.3, 1.0);
uniform float width_px = 2.0;
// 0..1 along the path: before `head` the line is drawn full, after it faint
// (the part of a year still to come). 1 = all full.
uniform float head = 1.0;
uniform float tail_alpha = 0.35;
// Dash length in pixels (0 = solid).
uniform float dash_px = 0.0;

varying float v_along;

void vertex() {
	vec4 pv = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec3 tv = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 view = normalize(pv.xyz);
	vec3 side = cross(tv, view);
	float sl = length(side);
	side = sl > 1e-5 ? side / sl : vec3(1.0, 0.0, 0.0);
	// World units per pixel at this depth: 2 d tan(fov/2) / viewport height.
	float per_px = 2.0 * max(-pv.z, 1e-6) / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	pv.xyz += side * UV.x * 0.5 * width_px * per_px;
	POSITION = PROJECTION_MATRIX * pv;
	v_along = UV.y;
}

void fragment() {
	float a = color.a * (v_along <= head ? 1.0 : tail_alpha);
	if (dash_px > 0.0) {
		float d = fract(FRAGCOORD.x / (2.0 * dash_px) + FRAGCOORD.y / (2.0 * dash_px));
		a *= step(0.5, d) * 0.6 + 0.4;
	}
	ALBEDO = color.rgb;
	ALPHA = a;
}
