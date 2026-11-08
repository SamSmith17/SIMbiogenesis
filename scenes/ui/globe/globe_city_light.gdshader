// One city light (GlobeCityLights): a camera-facing glow disc at a point of
// the ground. The instance transform carries the light's position and, as its
// scale, the ground footprint of the Black Marble pixel it came from (world
// units); INSTANCE_CUSTOM.r is the pixel's brightness, .g a hash for the
// colour. A disc never draws smaller than min_px on screen, so far lights stay
// points, and a sub-pixel light dims by how much of a pixel it covers rather
// than vanishing. Night side only. Additive, no depth write.
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, fog_disabled;

uniform vec3 sun_dir = vec3(0.0, 0.0, 1.0);
uniform float gain = 1.0;
uniform float min_px = 1.6;
uniform float spread = 1.5;
uniform vec3 sodium : source_color = vec3(1.0, 0.78, 0.45);
uniform vec3 led : source_color = vec3(0.86, 0.92, 1.0);

varying float v_luma;
varying float v_hash;
varying float v_cover;
varying vec3 v_n;

void vertex() {
	vec3 centre = MODEL_MATRIX[3].xyz;
	float foot = length(MODEL_MATRIX[0].xyz) * spread;
	vec4 cv = VIEW_MATRIX * vec4(centre, 1.0);
	float per_px = 2.0 * max(-cv.z, 1e-7) / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float s = max(foot, min_px * per_px);
	v_cover = clamp(foot / max(min_px * per_px, 1e-9), 0.08, 1.0);
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	vec3 wp = centre + (right * VERTEX.x + up * VERTEX.y) * s * 2.0;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(wp, 1.0);
	v_luma = INSTANCE_CUSTOM.r;
	v_hash = INSTANCE_CUSTOM.g;
	v_n = normalize(centre);
}

void fragment() {
	vec2 d2 = UV - vec2(0.5);
	float d = length(d2) * 2.0;
	float disc = exp(-d * d * 3.2) * (1.0 - smoothstep(0.75, 1.0, d));
	float dark = 1.0 - smoothstep(-0.16, 0.03, dot(v_n, normalize(sun_dir)));
	vec3 col = mix(sodium, led, step(0.72, v_hash));
	ALBEDO = col * disc * v_luma * dark * gain * v_cover;
}
