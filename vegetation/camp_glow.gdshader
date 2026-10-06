shader_type spatial;
// Cheap night lights for the camp city: one MultiMesh of camera-facing emissive
// dots, each carrying a random saturated colour via the MultiMesh instance COLOR
// (use_colors = true). `glow_intensity` is ramped from day (0) to night (~6) by
// the loader/light pool from the sun altitude, so the whole field lights up at
// dusk with a single uniform write and one draw call.
//
// Two tricks make the field read from a drone-height aerial view (the whole point
// of this shader), where 0.35 m markers used to shrink below a pixel and vanish:
//   1. Each instance is billboarded toward the camera in the vertex stage.
//   2. Distant markers hold a constant *apparent* size, so a far light never
//      shrinks away — it stays a visible point the WorldEnvironment glow can
//      bloom into a colourful dot, like Black Rock City shot from the air.
//
// IMPORTANT: the apparent-size term is computed purely in VIEW space (depth +
// projection), NOT from VIEWPORT_SIZE. VIEWPORT_SIZE is unreliable in the vertex
// stage (reported as (1,1) in some passes — see godot#82782); using it made every
// marker explode to tens of metres and paint the whole screen a solid colour.
// fog_disabled is LOAD-BEARING: Godot fogs unshaded/additive materials too,
// which mixes the fog colour into the WHOLE quad — by day (glow 0) every card
// became a light-blue rectangle up to 30 m across, and a field of them read as
// a bluish sheen over every camp seen at a low angle through haze.
render_mode unshaded, cull_disabled, shadows_disabled, blend_add, depth_draw_never, fog_disabled;

// 0 by day -> markers are nearly black and invisible. Raised at night so EMISSION
// blooms through the WorldEnvironment glow into colourful points of light.
uniform float glow_intensity = 0.0;
// Diameter of a marker in metres when viewed up close (below the angular floor).
uniform float world_size : hint_range(0.05, 5.0) = 0.6;
// Minimum apparent diameter as a fraction of the view frustum height at the
// marker's depth (≈ constant on-screen size). Bigger = brighter/easier to bloom.
uniform float min_angular_size : hint_range(0.0, 0.05) = 0.011;
// Absolute safety cap on a marker's world size, so no projection edge case can
// ever scale one up to fill the screen again.
uniform float max_world_size : hint_range(1.0, 200.0) = 30.0;
// Near fade: billboards closer than `near_fade_start` are invisible, ramping to
// full by `near_fade_end`. Without this, walking THROUGH the camp at night paints
// the screen with a few big emissive cards right in front of the camera. The
// mid/far field (the aerial "city at night" look) is unaffected.
uniform float near_fade_start : hint_range(0.0, 50.0) = 2.0;
uniform float near_fade_end : hint_range(0.0, 100.0) = 9.0;

// Lowest point of the shimmer (1.0 = steady).
uniform float twinkle_floor : hint_range(0.0, 1.0) = 0.3;

varying float v_dist;
varying float v_twinkle;

void vertex() {
	// Instance origin in view space (MODELVIEW includes the per-instance xform).
	vec4 origin_view = MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0);
	float dist = max(-origin_view.z, 0.001);
	v_dist = dist;
	// Hold a constant apparent size beyond the crossover distance: size grows
	// linearly with depth so (size / dist) — i.e. the on-screen size — is fixed.
	// Up close, never go below world_size; never exceed the hard cap.
	float s = clamp(dist * min_angular_size, world_size, max_world_size);
	// QuadMesh verts live in the XY plane (-0.5..0.5) -> billboarded by adding
	// them in view space, so the card always faces the camera (drone or ground).
	vec3 view_pos = origin_view.xyz + vec3(VERTEX.x, VERTEX.y, 0.0) * s;
	POSITION = PROJECTION_MATRIX * vec4(view_pos, 1.0);
	
	// A gentle shimmer (bulbs, wind in string lights), not a strobe.
	float t = TIME * 1.5 + float(INSTANCE_ID) * 2.1;
	v_twinkle = mix(twinkle_floor, 1.0, (sin(t) + sin(t * 1.7 + 1.2)) * 0.25 + 0.5);
}

void fragment() {
	if (glow_intensity <= 0.0) {
		discard;
	}
	// Round: a tight hot core plus a soft halo, reaching exactly zero at the
	// inscribed circle so no card ever shows a square edge.
	float r = length(UV - vec2(0.5)) * 2.0;
	if (r >= 1.0) {
		discard;
	}
	float halo = 1.0 - r;
	halo *= halo;
	float mask = halo * 0.45 + exp(-r * r * 28.0) * 0.55;
	// Fade out cards very close to the camera so a player standing among the camps
	// isn't blinded by full-screen emissive panels.
	float near_fade = smoothstep(near_fade_start, near_fade_end, v_dist);
	// Use ALBEDO + blend_add to purely add vibrant light to the background.
	// COLOR.a = this light's brightness (a household's main light 1.0, string
	// lights dimmer).
	ALBEDO = COLOR.rgb * COLOR.a * glow_intensity * mask * near_fade * v_twinkle;
	EMISSION = vec3(0.0);
}
