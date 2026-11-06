shader_type spatial;
// The atmosphere's glow, drawn on the BACK faces of a shell round the globe
// (additive, no depth write). Each pixel's view ray is followed to its
// closest approach to the Earth's centre; the glow is the air density there
// (exponential, scale height scale_h in Earth radii), blue where that point
// is sunlit, orange across the terminator. From inside the shell (a low
// camera) the same rule draws a sky that is brightest at the horizon.
render_mode unshaded, blend_add, cull_front, depth_draw_never;

uniform vec3 sun_dir = vec3(0.0, 0.0, 1.0);
uniform float scale_h = 0.012;
uniform float strength = 0.9;

varying vec3 w_pos;

void vertex() {
	w_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 d = normalize(w_pos - cam);
	float t = max(0.0, -dot(cam, d));
	vec3 cp = cam + d * t;
	float h = max(length(cp) - 1.0, 0.0);
	float dens = exp(-h / scale_h);
	float s = dot(normalize(cp), normalize(sun_dir));
	float day = smoothstep(-0.28, 0.22, s);
	vec3 c = mix(vec3(0.28, 0.52, 1.0), vec3(1.0, 0.45, 0.16), exp(-(s / 0.16) * (s / 0.16)) * 0.75);
	ALBEDO = c * day * dens * strength;
}
