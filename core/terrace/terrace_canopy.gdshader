shader_type spatial;
render_mode cull_disabled, diffuse_burley;

// A terrace's crop seen from further off (TerraceRuntime): each paddy's floor
// lifted to the crop's height as it grows, with sides down to the floor
// (UV2.y = 1 on the canopy, 0 at the floor; UV2.x = 1 on the sides). The same
// clock as the near plants (garden_crop.gdshader): now_d = days since the
// field was sown, one crop every `cycle` days, bare for `fallow` of it, full
// size at `mature`, ripening over the last part. UV = world XZ.

uniform float now_d = -1.0;
uniform float cycle = 120.0;
uniform float fallow = 0.04;
uniform float mature = 0.7;
uniform float height_m = 0.9;
uniform float ripen_from = 0.78;
// Set by TerraceRuntime from the paddy's own season (-1 = use now_d), and
// the share of the paddy standing (planting / cutting).
uniform float fixed_f = -1.0;
uniform float cover = 1.0;
uniform vec3 young : source_color = vec3(0.36, 0.62, 0.2);
uniform vec3 ripe : source_color = vec3(0.82, 0.68, 0.26);

varying float v_g;
varying float v_f;
varying float v_side;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

void vertex() {
	float age = now_d;
	float f = age >= 0.0 ? fract(age / max(cycle, 1.0)) : -1.0;
	if (fixed_f >= 0.0) {
		f = fixed_f;
	}
	float g = f < fallow ? 0.0 : smoothstep(fallow, mature, f) * clamp(cover, 0.0, 1.0);
	v_g = g;
	v_f = f;
	v_side = UV2.x;
	if (g < 0.06) {
		// Nothing standing yet: below the floor, out of sight.
		VERTEX.y -= 0.6;
	} else {
		VERTEX.y += UV2.y * height_m * g;
	}
}

void fragment() {
	vec2 p = UV;
	float n = vnoise(p * 2.7) * 0.55 + vnoise(p * 9.0) * 0.3 + vnoise(p * 31.0) * 0.15;
	float rows = 0.5 + 0.5 * sin(p.x * 14.0 + vnoise(p * 0.7) * 6.0);
	vec3 col = mix(young, ripe, smoothstep(ripen_from, 0.97, v_f));
	col *= 0.78 + 0.32 * n;
	col *= 0.92 + 0.08 * rows;
	col *= mix(1.0, 0.62, v_side);
	ALBEDO = col;
	ROUGHNESS = 0.86;
	SPECULAR = 0.25;
	BACKLIGHT = vec3(0.12, 0.16, 0.06);
}
