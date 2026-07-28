shader_type spatial;
// Desire-line heat draped on the terrain (POPULATION_PLAN.md Tier 3f).
//
// Additive and unshaded: the heat is light painted onto the ground, not a
// surface, so it must not take lighting or cast into the depth buffer. UVs are
// baked into the mesh as world-XZ over the map's rect, so there is no bbox
// uniform to keep in sync — the mesh IS the registration.
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D heat_tex : source_color, filter_linear, repeat_disable;
uniform float strength : hint_range(0.0, 3.0) = 1.0;

void fragment() {
	vec4 c = texture(heat_tex, UV);
	// Weight by the ramp's own alpha so cold ground contributes nothing and
	// the worn corridors glow.
	ALBEDO = c.rgb * c.a * strength;
	ALPHA = 1.0;
}
