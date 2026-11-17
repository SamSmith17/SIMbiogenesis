shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_never, specular_schlick_ggx;

// Standing water in a terrace paddy (TerraceRuntime). Shallow and a little
// muddy: the floor shows through where you look down into it, the sky where
// you look across it. Wind ripples from a few travelling sines in world space
// (no texture), so neighbouring paddies line up.

uniform vec3 shallow : source_color = vec3(0.46, 0.55, 0.56);
uniform vec3 deep : source_color = vec3(0.16, 0.26, 0.32);
uniform vec3 sky : source_color = vec3(0.72, 0.82, 0.92);
uniform float clarity = 0.42;
uniform float ripple = 0.35;

varying vec3 v_wp;

float wave(vec2 p, float t) {
	return sin(p.x * 1.9 + t * 0.9) * 0.5
		+ sin(p.y * 2.6 - t * 1.2) * 0.4
		+ sin((p.x + p.y) * 4.3 + t * 1.8) * 0.18
		+ sin((p.x - p.y) * 7.1 - t * 2.4) * 0.08;
}

void vertex() {
	v_wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = v_wp.xz;
	float e = 0.06;
	float hx = wave(p + vec2(e, 0.0), TIME) - wave(p - vec2(e, 0.0), TIME);
	float hz = wave(p + vec2(0.0, e), TIME) - wave(p - vec2(0.0, e), TIME);
	vec3 nw = normalize(vec3(-hx * ripple * 0.06 / e, 1.0, -hz * ripple * 0.06 / e));
	NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fres = pow(1.0 - facing, 4.0);
	// Shallow paddies mirror the sky: the reflection is most of what you see.
	ALBEDO = mix(mix(shallow, deep, 0.35), sky, 0.55 * fres + 0.15);
	ROUGHNESS = 0.04;
	METALLIC = 0.0;
	SPECULAR = 0.7;
	ALPHA = mix(1.0 - clarity, 0.94, fres);
}
