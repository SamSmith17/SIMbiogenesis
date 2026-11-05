shader_type spatial;
// A concentrator's mirror (CspLabBuilder): bright polished metal that never
// reads as black. Godot reflects only the sky's radiance on a metallic
// surface, and in the world that reflection is often dark (the sky below
// the horizon, a low player ambient, a forest round the site): a metallic
// 1.0 / roughness 0.06 dish read as black. So this is NOT a full mirror:
// it keeps a share of diffuse (METALLIC 0.72, a light albedo), so the sun
// and the ambient light it like any bright surface, and adds what a real
// mirror shows on top — the sky gradient in the reflected direction, the
// ground below it, and the sun's glint — scaled by daylight.
//
// Cost and gating: the painted reflection fades to one flat sky colour past
// `detail_far` (the glint and gradient are skipped there), and every
// concentrator in the world shares ONE material whose `sun_dir` / `daylight`
// the runtimes push at most twice a second, only when they moved
// (CspLabBuilder.push_world_sun). The designer's studio has its own copy.
render_mode cull_back, specular_schlick_ggx;

uniform vec3 tint : source_color = vec3(0.90, 0.92, 0.95);
uniform float roughness_v : hint_range(0.0, 1.0) = 0.10;
uniform float metallic_v : hint_range(0.0, 1.0) = 0.72;
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);
uniform float daylight : hint_range(0.0, 1.0) = 1.0;
uniform vec3 sky_zenith : source_color = vec3(0.30, 0.50, 0.86);
uniform vec3 sky_horizon : source_color = vec3(0.78, 0.86, 0.95);
uniform vec3 ground_col : source_color = vec3(0.42, 0.40, 0.36);
// How much of the painted reflection is added over the engine's own.
uniform float reflect_gain : hint_range(0.0, 2.0) = 0.45;
// The sun's glint (the disc and the bright halo the surface error spreads).
uniform float glint_gain : hint_range(0.0, 60.0) = 22.0;
uniform float glint_width : hint_range(0.001, 0.2) = 0.03;
// Past this distance (m) the reflection is one flat sky colour.
uniform float detail_far : hint_range(10.0, 1000.0) = 90.0;
// Moonlight / starlight on the mirror at night (it is never pitch black).
uniform float night_floor : hint_range(0.0, 0.3) = 0.05;

void fragment() {
	ALBEDO = tint;
	METALLIC = metallic_v;
	ROUGHNESS = roughness_v;
	SPECULAR = 0.5;
	float day = max(daylight, night_floor);
	// The flat sky a far mirror shows: between the horizon and the zenith.
	vec3 flat_sky = mix(sky_horizon, sky_zenith, 0.45);
	float dist = length(VERTEX);
	float near_k = 1.0 - smoothstep(detail_far * 0.6, detail_far, dist);
	vec3 env = flat_sky;
	vec3 glint_col = vec3(0.0);
	if (near_k > 0.0) {
		vec3 n_w = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
		vec3 v_w = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
		vec3 r = reflect(-v_w, n_w);
		vec3 grad;
		if (r.y >= 0.0) {
			grad = mix(sky_horizon, sky_zenith, sqrt(clamp(r.y, 0.0, 1.0)));
		} else {
			grad = mix(sky_horizon * 0.8, ground_col, clamp(-r.y * 5.0, 0.0, 1.0));
		}
		env = mix(flat_sky, grad, near_k);
		vec3 s = normalize(sun_dir);
		float c = max(dot(r, s), 0.0);
		// A narrow core plus a soft halo (1 − c ≈ θ²/2).
		float th2 = 2.0 * (1.0 - c);
		float glint = exp(-th2 / (glint_width * glint_width * 0.02)) + 0.08 * exp(-th2 / (glint_width * glint_width));
		float sun_up = smoothstep(-0.02, 0.06, s.y);
		glint_col = vec3(1.0, 0.96, 0.88) * glint * glint_gain * sun_up * near_k;
	}
	EMISSION = tint * (env * reflect_gain * day + glint_col);
}
