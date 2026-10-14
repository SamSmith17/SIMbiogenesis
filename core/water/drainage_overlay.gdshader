shader_type spatial;

// The derived drainage network drawn ON the terrain: ribbons coloured by
// Strahler order whose dashes run DOWNSTREAM, so "where does water go" reads
// at a glance. Unshaded and additive so it shows in shade and at night, with no
// depth write so it never fights the water surfaces.
// UV.x = arc length (m, downstream), UV.y = lateral −1..1, COLOR = tint + alpha.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled;

#include "res://core/soi/shaders/soi_clip.gdshaderinc"

uniform float dash_len_m = 6.0;
uniform float dash_speed_ms = 2.0;
uniform float strength : hint_range(0.0, 2.0) = 1.0;

varying vec3 v_world_pos;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	soi_clip_fragment(v_world_pos);
	float edge = 1.0 - smoothstep(0.55, 1.0, abs(UV.y));
	float ph = fract((UV.x - TIME * dash_speed_ms) / dash_len_m);
	float dash = 0.45 + 0.55 * smoothstep(0.0, 0.25, ph) * (1.0 - smoothstep(0.55, 0.85, ph));
	ALBEDO = COLOR.rgb * COLOR.a * edge * dash * strength;
}
