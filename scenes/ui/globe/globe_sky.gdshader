shader_type sky;
// The stars behind the globe. EYEDIR is in the globe's earth-fixed frame, so
// a direction's longitude plus Greenwich sidereal time is its right
// ascension (the same mapping as StarSkyMath.uv_from_equatorial, with the
// registration from assets/sky/starmap_equirect_8k.json), plus the Sun.

uniform sampler2D stars : source_color, filter_linear;
uniform bool has_stars = false;
uniform float gmst_deg = 0.0;
uniform float ra0_deg = 0.0;
uniform float ra_dir = -1.0;
uniform float gain = 0.55;
uniform vec3 sun_dir = vec3(0.0, 0.0, 1.0);

void sky() {
	vec3 d = normalize(EYEDIR);
	vec3 c = vec3(0.0);
	if (has_stars) {
		float lon = degrees(atan(d.x, d.z));
		float dec = degrees(asin(clamp(d.y, -1.0, 1.0)));
		float ra = lon + gmst_deg;
		float u = fract((ra - ra0_deg) * ra_dir / 360.0);
		float v = 0.5 - dec / 180.0;
		c = texture(stars, vec2(u, v)).rgb * gain;
	}
	float s = dot(d, normalize(sun_dir));
	c += vec3(1.0, 0.96, 0.88) * smoothstep(0.99996, 0.99999, s) * 12.0;
	c += vec3(1.0, 0.9, 0.7) * pow(max(s, 0.0), 900.0) * 0.5;
	COLOR = c;
}
