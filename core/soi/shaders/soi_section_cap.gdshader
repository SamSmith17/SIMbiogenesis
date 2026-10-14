shader_type spatial;
// Solid earth on the Elevation section's cut face (core/soi/soi_section_cap.gd).
//
// The CT cutaway discards the camera-side half of the terrain and the soil bowl,
// and nothing used to fill the plane it cuts along: looking side-on you saw the
// INSIDE of the far half of the bowl, and wherever the ground at the cut stood
// higher than the ground at the bowl's back rim the bowl's above/below-ground
// test threw the pixels away — sky showed through the ground. This cap is a
// strip mesh lying on the plane, from the terrain profile down to the sphere's
// chord circle, painted with the SAME strata as the bowl (soi_strata.gdshaderinc).
//
// unshaded: the strata are self-lit poster colours (the bowl writes them as
// EMISSION over a black albedo, which reads identically). Opaque, so it wins the
// depth test against the alpha-blended bowl behind it. No section-plane discard
// of its own — it sits a few centimetres BEHIND the plane by construction.
render_mode unshaded, cull_disabled, fog_disabled, depth_draw_opaque;

#include "res://core/soi/shaders/soi_strata.gdshaderinc"

global uniform vec4 soi_center_radius;
global uniform vec4 soi_section_normal;

/// Raises the top-edge vertices (UV2.y == 1) a hair so no sky sliver shows
/// between the cap and the terrain mesh at deep zoom. Set by the cap node from
/// the section's ortho height.
uniform float lip_m = 0.05;
/// Fade-in after a lens transition (0..1).
uniform float reveal = 1.0;
/// The terrain's near-field ground maps (TerrainBuilder) — the soil's grain.
uniform sampler2D soil_tex : source_color, filter_linear_mipmap, repeat_enable, hint_default_white;
uniform sampler2D soil_nrm : filter_linear_mipmap, repeat_enable, hint_normal;
uniform float use_soil_tex = 0.0;

varying vec3 v_world_pos;
varying float v_surface_y;

void vertex() {
	if (UV2.y > 0.5) {
		VERTEX.y += lip_m;
	}
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_surface_y = UV2.x;
}

void fragment() {
	if (reveal < 0.999) {
		// Screen-door fade (opaque pass, no sorting): a 4×4 ordered dither.
		ivec2 q = ivec2(FRAGCOORD.xy) % 4;
		int idx = q.x + q.y * 4;
		float bayer[16] = float[16](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0,
				3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
		if ((bayer[idx] + 0.5) / 16.0 > reveal) {
			discard;
		}
	}
	// Face coordinates: metres along the cut (the plane's horizontal axis),
	// world height.
	vec2 along = normalize(vec2(soi_section_normal.z, -soi_section_normal.x) + vec2(1e-6));
	vec2 face = vec2(dot(v_world_pos.xz, along), v_world_pos.y);
	ALBEDO = soi_soil(face, v_surface_y, soi_center_radius, TIME, soil_tex, soil_nrm,
			use_soil_tex, 1.0);
}
