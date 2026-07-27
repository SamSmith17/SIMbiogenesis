shader_type spatial;
// depth_test_disabled: Elev/Site CT soil bowl must not hide buried runs —
// wires read through / on top of the opaque ground fill.
render_mode unshaded, cull_disabled, depth_draw_opaque, depth_test_disabled;

// Cheap UV-scroll flow overlay for 3D conduits.
// V runs along the tube length (from ConduitMeshBuilder); scroll a soft band.

#include "res://core/soi/shaders/soi_clip.gdshaderinc"

uniform vec4 base_color : source_color = vec4(0.35, 0.85, 1.0, 1.0);
uniform vec4 flow_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float flow_speed : hint_range(0.0, 8.0) = 1.2;
uniform float flow_strength : hint_range(0.0, 2.0) = 0.85;
uniform float pulse : hint_range(0.0, 1.0) = 0.35;
uniform float conceptual : hint_range(0.0, 1.0) = 1.0;
uniform float emission_boost : hint_range(0.0, 6.0) = 2.2;
uniform float time_offset : hint_range(0.0, 100.0) = 0.0;

varying vec3 v_world_pos;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	soi_clip_fragment(v_world_pos);
	float along = UV.y;
	float phase = along * 4.0 - (TIME + time_offset) * flow_speed;
	// Soft repeating band (conceptual) or thinner dashes (physical overlay).
	float band_w = mix(0.12, 0.28, conceptual);
	float band = smoothstep(band_w, 0.0, abs(fract(phase) - 0.5));
	float dash = smoothstep(0.35, 0.15, abs(fract(phase * 2.2) - 0.5));
	float flow = mix(dash, band, conceptual) * flow_strength;
	float breathe = 0.85 + pulse * 0.15 * sin(TIME * 2.4 + along * 6.28318);
	vec3 base = base_color.rgb * breathe;
	vec3 col = mix(base, flow_color.rgb, clamp(flow, 0.0, 1.0));
	float alpha = mix(1.0, 0.92, conceptual);
	ALBEDO = col;
	EMISSION = col * (emission_boost * (0.55 + flow * 0.9));
	ALPHA = alpha;
}
