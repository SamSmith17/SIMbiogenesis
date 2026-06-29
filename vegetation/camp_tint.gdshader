shader_type spatial;
// Per-instance tint for procedurally-generated camp structures (tarps, tents,
// shade cloth). Driven by MultiMesh instance colours: with `use_colors = true`
// the per-instance colour arrives in the built-in COLOR, which we multiply into
// the albedo so every tent/tarp gets its own random hue from one draw call.
render_mode cull_disabled, diffuse_burley;

uniform float roughness_val : hint_range(0.0, 1.0) = 0.92;
uniform float metallic_val : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = roughness_val;
	METALLIC = metallic_val;
}
