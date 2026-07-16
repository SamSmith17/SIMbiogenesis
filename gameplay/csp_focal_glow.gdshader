shader_type spatial;
// Camera-facing additive "hot spot" card layered over the CSP focal absorber
// tube. A self-emissive StandardMaterial3D alone reads as flat white during
// the day: this project's WorldEnvironment deliberately keeps daytime bloom
// to a compact core (fine mips only, no wide veil — see main.gd's glow setup
// comments) so mid-brightness emissive surfaces don't wash the whole scene
// out, but that also means a merely-bright mesh surface never looks
// "blinding". This card fakes the missing punch with an actual soft radial
// falloff drawn straight into the HDR framebuffer via additive blending —
// same trick as vegetation/camp_glow.gdshader's night-light dots — so the
// tube reads as a small sun even when the global bloom pipeline is tuned
// conservative for daytime.
render_mode blend_add, depth_draw_never, cull_disabled, unshaded, shadows_disabled;

// Overall brightness, driven every poll by CspTroughTracker from
// dni * cos_incidence (cloud cover + low-sun-angle attenuation already baked
// into both terms via CspTroughSource/SolarIrradiance).
uniform float brightness : hint_range(0.0, 40.0) = 0.0;
uniform vec3 tint : source_color = vec3(1.0, 1.0, 1.0);
// Card diameter in world metres (roughly the tube's cross-section — kept
// small so the effect reads as a hot point on the tube, not a giant sun).
uniform float world_size : hint_range(0.05, 5.0) = 0.5;

void vertex() {
	// There is no built-in "billboard" render_mode for spatial shaders —
	// camera-facing has to be done by hand (same technique as
	// vegetation/camp_glow.gdshader): take the node's origin in VIEW space
	// from MODELVIEW_MATRIX, then offset by the unit quad's local X/Y
	// directly in view space (so it always faces the camera) scaled by
	// `world_size` in metres — deliberately NOT multiplied by MODEL_MATRIX,
	// so the card's on-screen size is correct regardless of any scale baked
	// into the model's node chain above it.
	vec4 origin_view = MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0);
	vec3 view_pos = origin_view.xyz + vec3(VERTEX.x, VERTEX.y, 0.0) * world_size;
	POSITION = PROJECTION_MATRIX * vec4(view_pos, 1.0);
}

void fragment() {
	vec2 d = UV - vec2(0.5);
	float r = length(d) * 2.0;
	// Bright near-white core, soft additive falloff toward the edge — a cheap
	// stand-in for a real point-spread / diffraction glow.
	float core = clamp(1.0 - r * r, 0.0, 1.0);
	float halo = pow(clamp(1.0 - r, 0.0, 1.0), 2.5);
	ALBEDO = tint * brightness * (core * 0.6 + halo * 0.4);
}
