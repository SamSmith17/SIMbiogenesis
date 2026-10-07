shader_type spatial;
// The far tier of the crowd: past `figure_dist` every person is a camera-
// facing dot of constant APPARENT size, so the settlement view at 1200 m
// still shows a thousand pastel marks where a thousand people are — instead
// of nobody. Same slot layout as crowd_figure.gdshader (the two MultiMeshes
// hold the same people; this one draws only where that one collapses).
// Apparent size is computed in VIEW space, never from VIEWPORT_SIZE (see
// camp_glow.gdshader for why).
render_mode unshaded, cull_disabled, shadows_disabled, depth_draw_opaque;

uniform float t_rel = 0.0;
uniform float figure_dist = 150.0;
uniform float card_dist = 3000.0;    // nothing draws beyond this
uniform float lod_dist = 0.0;
uniform float draw_mode = 1.0;
uniform float world_size = 0.9;      // metres across when close enough to matter
uniform float min_angular = 0.0045;  // ≈ constant on-screen size beyond the crossover
uniform float max_world_size = 40.0;
uniform float night_glow = 0.0;      // lifted at night so the field reads like lights
uniform sampler2D height_tex : filter_linear, repeat_disable;
uniform vec4 height_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform float height_ready = 0.0;

varying vec3 v_tint;
varying float v_show;

void vertex() {
	vec3 a = MODEL_MATRIX[0].xyz;
	vec3 b = MODEL_MATRIX[1].xyz;
	float t0 = MODEL_MATRIX[2].x;
	float t1 = MODEL_MATRIX[2].y;
	float flags = MODEL_MATRIX[3].z;
	v_tint = COLOR.rgb;
	float span = max(t1 - t0, 1e-6);
	float u = clamp((t_rel - t0) / span, 0.0, 1.0);
	vec3 p = mix(a, b, u);
	if (height_ready > 0.5) {
		vec2 huv = (p.xz - height_rect.xy) / max(height_rect.zw, vec2(1e-3));
		if (huv.x >= 0.0 && huv.x <= 1.0 && huv.y >= 0.0 && huv.y <= 1.0) {
			p.y = textureLod(height_tex, huv, 0.0).r;
		}
	}
	p += vec3(0.0, 0.9, 0.0);   // chest height
	vec4 origin_view = VIEW_MATRIX * vec4(p, 1.0);
	float dist = max(-origin_view.z, 0.001);
	float far = distance(p, CAMERA_POSITION_WORLD);
	bool show = flags < 1.0 && draw_mode > 0.5 && far >= figure_dist && far <= card_dist
		&& (lod_dist <= 0.0 || far <= lod_dist);
	v_show = show ? 1.0 : 0.0;
	float s = clamp(dist * min_angular, world_size, max_world_size);
	vec3 view_pos = origin_view.xyz + vec3(VERTEX.x, VERTEX.y, 0.0) * s;
	if (!show) {
		view_pos = vec3(0.0, 0.0, 1.0);
	}
	POSITION = PROJECTION_MATRIX * vec4(view_pos, 1.0);
}

void fragment() {
	vec2 d = UV - vec2(0.5);
	float r = length(d) * 2.0;
	if (v_show < 0.5 || r > 1.0) {
		discard;
	}
	// A dark body with the pastel rim, like the figure up close.
	float edge = smoothstep(0.55, 1.0, r);
	ALBEDO = mix(vec3(0.03, 0.035, 0.05), v_tint, edge * 0.9);
	EMISSION = v_tint * (0.12 + night_glow) * edge;
}
