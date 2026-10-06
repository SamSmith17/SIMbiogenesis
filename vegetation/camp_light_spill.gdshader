shader_type spatial;
// The light a camp lamp throws on the ground around it, seen from FAR away —
// one flat additive disc per household light (CampAreaRuntime's
// CampLightSpill_MM). Up close the real OmniLights (CampLightPool) do this
// properly; they only exist within the pool's reach of the camera, so beyond
// it a drone or a hillside view used to see bare points with no light on the
// ground between the tents. This fades IN across the same band the pool's
// lights fade OUT, so the hand-off is invisible.
//
// Depth-TESTED on purpose: a tent standing on the disc hides the part under
// it, which leaves light pooling on the ground BETWEEN structures — the look
// of a camp at night from the air. fog_disabled for the reason in
// camp_glow.gdshader (fogged additive quads are coloured rectangles by day).
render_mode unshaded, cull_disabled, shadows_disabled, blend_add, depth_draw_never, fog_disabled;

// Written by CampLightPool from the sun altitude (0 by day).
uniform float glow_intensity = 0.0;
// glow_intensity is tuned for the HDR card cores; a ground pool wants a small
// fraction of it.
uniform float strength : hint_range(0.0, 0.2) = 0.018;
// Camera distance (m) over which the pool fades in.
uniform vec2 fade_in_m = vec2(90.0, 200.0);

varying float v_dist;

void vertex() {
	vec4 origin_view = MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0);
	v_dist = length(origin_view.xyz);
}

void fragment() {
	if (glow_intensity <= 0.0) {
		discard;
	}
	float r = length(UV - vec2(0.5)) * 2.0;
	if (r >= 1.0) {
		discard;
	}
	// Inverse-square-ish falloff that reaches zero at the rim.
	float fall = (1.0 - r) * (1.0 - r) / (1.0 + r * r * 6.0);
	float fade = smoothstep(fade_in_m.x, fade_in_m.y, v_dist);
	ALBEDO = COLOR.rgb * COLOR.a * glow_intensity * strength * fall * fade;
}
