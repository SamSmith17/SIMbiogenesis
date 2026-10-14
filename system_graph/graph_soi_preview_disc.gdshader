shader_type canvas_item;

/// Soft circular mask so the SoI SubViewport reads as a disc, not a square.
/// When `use_pixel_disc` is set, the disc is defined in container pixels so the
/// preview can cover the canvas while staying locked to the 2D SoI ring at any zoom.
/// `use_mask` 0 shows the whole container (the Hydro Lab embed).
uniform float edge_softness : hint_range(0.0, 0.08) = 0.008;
uniform int use_mask = 1;
uniform int use_pixel_disc = 0;
uniform vec2 disc_center_px = vec2(0.5, 0.5);
uniform float disc_radius_px = 1.0;
uniform vec2 container_size_px = vec2(1.0, 1.0);

/// Section (CT) backdrop. A side-on ORTHOGRAPHIC camera sees the sky only along
/// one direction — the horizon — and this project's sky is lit near the horizon
/// mostly by the volumetric fog the preview turns off, so the section's sky
/// rendered black. The section viewport renders with a transparent clear and
/// the empty air is painted here instead: a poster sky that follows the time
/// of day (colours set per capture from DaylightModel by the preview service),
/// deepening from the site's ground level up — the illustrated-diagram partner
/// of the strata cut below it.
uniform float backdrop_on = 0.0;
uniform vec4 backdrop_top : source_color = vec4(0.30, 0.52, 0.84, 1.0);
uniform vec4 backdrop_horizon : source_color = vec4(0.74, 0.85, 0.95, 1.0);
/// Container UV y (0 = top) of the horizon line (the SoI ground level).
uniform float backdrop_horizon_y = 0.6;
/// Below the horizon, outside the cut sphere: the section now fills its whole
/// panel (no disc mask), so the air beside the sphere under ground level is
/// painted as earth rather than as sky — a diagram's ground band, darkening
/// with depth, so the cut reads as "sky above, ground below" at any zoom.
uniform vec4 backdrop_ground : source_color = vec4(0.16, 0.13, 0.10, 1.0);
uniform vec4 backdrop_ground_deep : source_color = vec4(0.07, 0.06, 0.05, 1.0);

void fragment() {
	float a = 1.0;
	if (use_mask > 0) {
		if (use_pixel_disc > 0) {
			vec2 p = UV * container_size_px;
			float rr = length(p - disc_center_px) / max(disc_radius_px, 1.0);
			a = 1.0 - smoothstep(1.0 - edge_softness, 1.0, rr);
		} else {
			vec2 uv = UV * 2.0 - 1.0;
			float rr = length(uv);
			a = 1.0 - smoothstep(1.0 - edge_softness, 1.0, rr);
		}
	}
	COLOR = texture(TEXTURE, UV);
	if (backdrop_on > 0.5) {
		float hy = clamp(backdrop_horizon_y, 0.02, 0.98);
		float t = clamp((hy - UV.y) / hy, 0.0, 1.0);
		vec3 sky = mix(backdrop_horizon.rgb, backdrop_top.rgb, pow(t, 0.7));
		// Under the horizon: a ground band, darker with depth, with a soft
		// 1.5 % lip so the ground line itself is not a hard seam.
		float depth = clamp((UV.y - hy) / max(1.0 - hy, 0.02), 0.0, 1.0);
		vec3 ground = mix(backdrop_ground.rgb, backdrop_ground_deep.rgb, pow(depth, 0.6));
		float below = smoothstep(hy - 0.004, hy + 0.012, UV.y);
		vec3 air = mix(sky, ground, below);
		COLOR.rgb = mix(air, COLOR.rgb, COLOR.a);
		COLOR.a = 1.0;
	}
	COLOR.a *= a;
	if (COLOR.a < 0.01) {
		discard;
	}
}
