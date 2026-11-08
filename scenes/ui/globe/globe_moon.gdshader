// The Moon. Unshaded, lit by the globe's Sun (sun_dir, the globe frame; the
// node's own transform turns the body). Sunlight on an airless body: a sharp
// terminator, a faint earthshine floor on the night side. The irradiance
// overlay is the clear-sky cosine law, 0 to the solar constant (1361 W/m²),
// painted as a continuous ramp with a contour every 200 W/m², over the real
// surface so the maria still read through it.
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool has_tex = false;
uniform bool irradiance = false;
uniform float overlay_alpha = 0.62;
uniform vec3 sun_dir = vec3(0.0, 0.0, 1.0);
uniform vec3 tint : source_color = vec3(0.58, 0.57, 0.54);

const float SOLAR_CONSTANT = 1361.0;

varying vec3 w_n;
varying vec3 local_n;

void vertex() {
	local_n = VERTEX;
	w_n = (MODEL_MATRIX * vec4(VERTEX, 0.0)).xyz;
}

float luminance_hint(vec3 c) {
	return clamp(dot(c, vec3(0.3, 0.59, 0.11)) * 1.8, 0.35, 1.0);
}

// 0..1361 W/m² -> the same ramp as the globe's irradiance legend: night
// blue, dawn blue, white, gold at the subsolar point.
vec3 irr_color(float w) {
	float e = w / SOLAR_CONSTANT;
	vec3 c = mix(vec3(0.03, 0.06, 0.16), vec3(0.30, 0.55, 0.92), smoothstep(0.0, 0.3, e));
	c = mix(c, vec3(0.96, 0.95, 0.88), smoothstep(0.3, 0.72, e));
	c = mix(c, vec3(1.0, 0.80, 0.25), smoothstep(0.72, 1.0, e));
	return c;
}

void fragment() {
	vec3 ln = normalize(local_n);
	vec3 wn = normalize(w_n);
	float lat = asin(clamp(ln.y, -1.0, 1.0));
	float lon = atan(ln.x, ln.z);
	vec2 uv = vec2(fract(lon / TAU + 0.5), 0.5 - lat / PI);
	vec3 day = tint;
	if (has_tex) {
		day = texture(albedo_tex, uv).rgb;
	} else {
		float maria = smoothstep(0.55, 0.8, fract(sin(dot(uv * vec2(3.0, 5.0), vec2(12.9, 78.2))) * 43758.5));
		float blot = smoothstep(0.18, 0.02, length(uv - vec2(0.38, 0.46)));
		blot += smoothstep(0.12, 0.02, length(uv - vec2(0.55, 0.58)));
		day = mix(vec3(0.62, 0.61, 0.58), vec3(0.26, 0.25, 0.24), clamp(maria * 0.7 + blot, 0.0, 1.0));
	}
	float ndl = dot(wn, normalize(sun_dir));
	// No air: the terminator is sharp, the night side only earthshine.
	float lit = smoothstep(-0.015, 0.06, ndl);
	// A touch of the opposition surge (regolith brightens toward full phase).
	vec3 v = normalize(CAMERA_POSITION_WORLD - (MODEL_MATRIX * vec4(local_n, 1.0)).xyz);
	float surge = 1.0 + 0.18 * pow(max(dot(v, normalize(sun_dir)), 0.0), 8.0);
	vec3 col = day * mix(0.012, 1.0, lit) * (0.86 + 0.14 * clamp(ndl, 0.0, 1.0)) * surge;
	if (irradiance) {
		float w = SOLAR_CONSTANT * clamp(ndl, 0.0, 1.0);
		vec3 oc = irr_color(w);
		// Contours every 200 W/m² and the terminator itself.
		float band = abs(fract(w / 200.0 + 0.5) - 0.5) * 200.0;
		float fw = max(fwidth(w), 1e-3);
		float line = 1.0 - smoothstep(0.6 * fw, 1.8 * fw, band);
		float term = 1.0 - smoothstep(0.0, 2.5 * max(fwidth(ndl), 1e-4), abs(ndl));
		vec3 shaded = mix(col, oc * (0.55 + 0.45 * luminance_hint(day)), overlay_alpha);
		shaded = mix(shaded, vec3(0.1, 0.1, 0.12), line * 0.45 * step(1.0, w));
		shaded = mix(shaded, vec3(1.0, 0.95, 0.8), term * 0.6);
		col = shaded;
	}
	ALBEDO = col;
}
