shader_type spatial;
// Physical conduit runs (culvert, penstock, PVC, hose…) are x-ray by design —
// depth_test_disabled so the Elevation / Site CT soil bowl never hides a buried
// run. In the world that read as a pipe glowing through the hill with no sense
// of depth. ConduitMeshBuilder / ConduitManager stamp each vertex's BURIAL
// (ground height above the vertex, metres; 0 on or above the surface) into
// UV2.x, and this shader fades, desaturates and dashes the run with depth, so
// a span under 3 m of hill reads as "buried here", a span on the surface as
// the pipe itself. The dotted ground trace above buried spans is a separate
// mesh (ConduitManager._apply_burial_cue).
render_mode cull_disabled, depth_draw_opaque, depth_test_disabled;

#include "res://core/soi/shaders/soi_clip.gdshaderinc"

uniform vec4 base_color : source_color = vec4(0.6, 0.6, 0.6, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.7;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
/// Burial at which the run is fully faded.
uniform float fade_depth_m : hint_range(0.1, 20.0) = 3.0;
/// Alpha of a fully buried run (never 0 — the player must still find it).
uniform float buried_alpha : hint_range(0.0, 1.0) = 0.38;
/// Dashes per unit of UV.y along the run when buried.
uniform float dash_freq : hint_range(1.0, 200.0) = 40.0;

varying vec3 v_world_pos;
varying float v_burial;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_burial = max(UV2.x, 0.0);
}

void fragment() {
	soi_clip_fragment(v_world_pos);
	float b = clamp(v_burial / max(fade_depth_m, 0.01), 0.0, 1.0);
	// Only a run that is genuinely under the ground takes the cue; the first
	// 5 cm is drape noise.
	b *= smoothstep(0.03, 0.12, v_burial);
	vec3 col = base_color.rgb;
	float lum = dot(col, vec3(0.299, 0.587, 0.114));
	vec3 grey = vec3(lum) * 0.75;
	// Hidden-line dashes along the run, stronger the deeper it goes.
	float dash = step(0.5, fract(UV.y * dash_freq));
	float dash_mix = mix(1.0, mix(0.55, 1.0, dash), b);
	ALBEDO = mix(col, grey, 0.65 * b) * dash_mix;
	ROUGHNESS = roughness;
	METALLIC = metallic;
	ALPHA = mix(1.0, buried_alpha * mix(0.6, 1.0, dash), b);
}
