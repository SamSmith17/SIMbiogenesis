shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, blend_mix;

// The coherent water jet between a Pelton nozzle and its runner.
//
// A real Pelton jet at 6-20 m/s is a solid glassy ROD, not spray — the spray is
// what happens after it hits a bucket. So this is a thin cylinder with streaks
// scrolling along it at the true jet velocity, plus a fresnel rim so it reads wet
// and round rather than as a painted stick.
//
// The scroll rate is speed_ms / jet_len_m, i.e. one jet-length per (len/speed)
// seconds — the ONE thing that makes "more head = faster jet" legible instead of
// the jet just getting slightly brighter.
//
// Deliberately written from scratch rather than reusing terrain_river/terrain_water:
// both of those #include soi_clip.gdshaderinc, and in an own_world_3d studio
// viewport the clip uniforms are unset, which can make the surface vanish
// entirely. core/conduits/conduit_flow.gdshader's marching-band idea is the
// reference here, not the file.

uniform float speed_ms = 12.0;      // real jet velocity (PeltonPhysics.jet_velocity_ms)
uniform float jet_len_m = 0.15;     // nozzle mouth -> runner pitch circle
uniform float t = 0.0;              // seconds, driven from _process
uniform float intensity = 1.0;      // 0 = off, 1 = full flow
uniform vec3 water_tint : source_color = vec3(0.62, 0.86, 1.0);

varying vec3 v_view_normal;

void vertex() {
	v_view_normal = normalize(NORMAL);
}

// Cheap value noise — the jet is small on screen, so streaks only need to break
// up the surface, not be physically meaningful.
float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	return fract(p * (p + p));
}

void fragment() {
	if (intensity <= 0.001) {
		discard;
	}
	// UV.y runs along the jet on a CylinderMesh. One full jet length per
	// (jet_len_m / speed_ms) seconds.
	float scroll = t * (speed_ms / max(jet_len_m, 0.001));
	float u = UV.y * 6.0 - scroll;
	// Three offset streak bands so the surface shears rather than sliding rigidly.
	float streak = 0.0;
	streak += hash11(floor(u * 3.0));
	streak += hash11(floor(u * 5.0 + 11.0)) * 0.6;
	streak += hash11(floor(u * 9.0 + 41.0)) * 0.3;
	streak = clamp(streak / 1.9, 0.0, 1.0);

	// Fresnel: a round column is brightest at its silhouette.
	float fres = pow(1.0 - abs(dot(normalize(v_view_normal), vec3(0.0, 0.0, 1.0))), 1.6);

	vec3 col = water_tint * (0.55 + 0.45 * streak);
	col += vec3(1.0) * fres * 0.55;
	ALBEDO = col;
	// Slightly translucent, opaque enough to read as a solid rod of water.
	ALPHA = clamp((0.55 + 0.35 * fres) * intensity, 0.0, 1.0);
	EMISSION = col * 0.35 * intensity;
}
