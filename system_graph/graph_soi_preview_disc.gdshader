shader_type canvas_item;

/// Soft circular mask so the SoI SubViewport reads as a disc, not a square.
/// When `use_pixel_disc` is set, the disc is defined in container pixels so the
/// preview can cover the canvas while staying locked to the 2D SoI ring at any zoom.
uniform float edge_softness : hint_range(0.0, 0.08) = 0.02;
uniform int use_pixel_disc = 0;
uniform vec2 disc_center_px = vec2(0.5, 0.5);
uniform float disc_radius_px = 1.0;
uniform vec2 container_size_px = vec2(1.0, 1.0);

void fragment() {
	float a;
	if (use_pixel_disc > 0) {
		vec2 p = UV * container_size_px;
		float rr = length(p - disc_center_px) / max(disc_radius_px, 1.0);
		a = 1.0 - smoothstep(1.0 - edge_softness, 1.0, rr);
	} else {
		vec2 uv = UV * 2.0 - 1.0;
		float rr = length(uv);
		a = 1.0 - smoothstep(1.0 - edge_softness, 1.0, rr);
	}
	COLOR = texture(TEXTURE, UV);
	COLOR.a *= a;
	if (COLOR.a < 0.01) {
		discard;
	}
}
