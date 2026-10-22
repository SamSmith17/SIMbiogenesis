shader_type fog;

// Valley / radiation ground fog: a layer of uniform extinction up to an
// ABSOLUTE world height, feathered at its top, broken up by slow drifting
// noise. Because the top is a world height and not "N metres above the local
// ground", the fog fills hollows and lets the ridges stand out of it — the way
// a cold pool actually fogs a valley.
//
// DENSITY uses the same units as Environment.volumetric_fog_density, i.e. the
// extinction coefficient sigma (1/m); Koschmieder visibility = 3.912 / sigma.

uniform float density_sigma = 0.0;
uniform float top_y = 0.0;
uniform float feather_m = 12.0;
uniform vec3 albedo : source_color = vec3(0.85, 0.87, 0.9);
uniform float noise_amount = 0.35;
uniform float noise_scale = 0.018;
uniform vec3 drift = vec3(0.0);
// Diffuse skylight scattered by the droplets. A fog is lit mostly by the sky
// dome, not the sun — without this term a dawn fog (low sun, little ambient)
// renders as black murk. main.gd drives it off DaylightModel.sky_light.
uniform vec3 sky_emission = vec3(0.0);
// Blowing dust (main.gd's DustLayer) streams ALONG the wind: the noise is
// stretched along `wind_dir` (world XZ, the way the air moves) by `streak`,
// and `gust_amount` adds broad dense bands that sweep through downwind (the
// pulses of a real dust storm). The valley fog leaves all three at their
// defaults, which reproduce its old isotropic noise exactly.
uniform vec2 wind_dir = vec2(1.0, 0.0);
uniform float streak = 0.0;
uniform float gust_amount = 0.0;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash13(i);
	float n100 = hash13(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash13(i + vec3(0.0, 1.0, 0.0));
	float n110 = hash13(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash13(i + vec3(0.0, 0.0, 1.0));
	float n101 = hash13(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash13(i + vec3(0.0, 1.0, 1.0));
	float n111 = hash13(i + vec3(1.0, 1.0, 1.0));
	return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
		mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

void fog() {
	float h = 1.0 - smoothstep(top_y - feather_m, top_y + feather_m * 0.35, WORLD_POSITION.y);
	vec3 p = WORLD_POSITION + drift;
	// Into the wind's frame: along / up / across. With wind_dir (1, 0) this is
	// (x, y, z), i.e. the valley fog's original coordinates.
	vec2 d = length(wind_dir) > 0.001 ? normalize(wind_dir) : vec2(1.0, 0.0);
	vec2 c = vec2(-d.y, d.x);
	float along = dot(p.xz, d);
	float across = dot(p.xz, c);
	vec3 q = vec3(along / (1.0 + streak * 7.0), p.y, across) * noise_scale;
	// Flatter cells vertically: fog banks are wide and shallow.
	q.y *= 2.5;
	float n = vnoise(q) * 0.65 + vnoise(q * 2.7) * 0.35;
	float breakup = mix(1.0, smoothstep(0.15, 0.85, n) * 1.7, noise_amount);
	// Gust bands: broad, across-wind fronts of denser dust moving downwind.
	if (gust_amount > 0.001) {
		float g = vnoise(vec3(along * 0.0045, 0.0, across * 0.0012));
		breakup *= mix(1.0, 0.35 + 1.5 * smoothstep(0.25, 0.8, g), gust_amount);
	}
	DENSITY = density_sigma * h * breakup;
	ALBEDO = albedo;
	EMISSION = sky_emission * h;
}
