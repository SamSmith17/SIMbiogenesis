shader_type spatial;
// The snowglobe camera can now fly inside the sphere (see
// soi_snowglobe_camera.gd MIN_ORBIT_MULT), so a single fixed cull face no
// longer works: from outside, the near (outward-facing) triangle must win;
// from inside, the near (inward-facing) triangle must win instead. Rendering
// both sides (cull_disabled) and forcing a depth WRITE even though the
// material is alpha-blended (depth_draw_always) lets the hardware Z-buffer
// pick whichever side is actually nearest to the camera at each pixel,
// regardless of draw order or which side of the sphere the camera is on —
// exactly one surface survives per pixel either way, so there's no double
// blending. FRONT_FACING then tells us whether that surviving triangle is
// the "outside" or "inside" wall so lighting/fresnel still point outward.
// fog_disabled: at snowglobe viewing distance the atmosphere was bleaching the
// cutaway to pastel — the cross-section is a diagram, not scenery, so it keeps
// its authored colors regardless of camera distance.
render_mode blend_mix, depth_draw_always, cull_disabled, diffuse_lambert, fog_disabled;

global uniform vec4 soi_center_radius;
global uniform float soi_clip_enabled;
global uniform vec4 soi_section_plane;
global uniform vec4 soi_section_normal;
global uniform float soi_ground_y;
global uniform float soi_water_table_m;
/// When 0, above-ground glass is discarded so sky/clouds show (Elevation section
/// / Site Plan). Below-ground soil cutaway still draws.
uniform float glass_enabled = 1.0;
/// Multiplier on glass alpha (Snowglobe pitch fade near horizon).
uniform float glass_opacity = 1.0;
/// Site Plan top-down: paint the below-ground bowl a flat ground-tan fill
/// instead of the water-cycle diagram (soil gradient + percolation veins +
/// aquifer). The plan wants "solid earth under the terrain", not a poster.
uniform float plain_soil = 0.0;
/// The terrain's near-field ground maps (TerrainBuilder) — the soil's grain.
uniform sampler2D soil_tex : source_color, filter_linear_mipmap, repeat_enable, hint_default_white;
uniform sampler2D soil_nrm : filter_linear_mipmap, repeat_enable, hint_normal;
uniform float use_soil_tex = 0.0;

varying vec3 v_world_pos;
varying float v_terrain_y;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_terrain_y = UV2.x;
}

#include "res://core/soi/shaders/soi_strata.gdshaderinc"

void fragment() {
	if (soi_clip_enabled < 0.5) {
		discard;
	}
	if (soi_section_plane.w > 0.5) {
		vec3 to_p = v_world_pos - soi_section_plane.xyz;
		if (dot(to_p, soi_section_normal.xyz) > 0.0) {
			discard;
		}
	}

	// Flip the normal for back-facing triangles (the wall we see when the
	// camera is inside the sphere) so lighting/fresnel always treat it as
	// facing the camera, same trick as vegetation/leaf_canopy.gdshader.
	vec3 nrm = NORMAL;
	if (!FRONT_FACING) {
		nrm = -NORMAL;
	}
	NORMAL = nrm;

	// NORMAL and VIEW are both in view space here, so this fresnel term is
	// correct and camera-angle-stable (see the render_mode comment above).
	float ndv = clamp(dot(normalize(nrm), normalize(VIEW)), 0.0, 1.0);
	float fresnel = pow(1.0 - ndv, 4.0);

	float surface_y = v_terrain_y;
	if (v_world_pos.y > surface_y - 0.05) {
		// ---- Above ground: glass "bubble" shell (the snowglobe dome) ----
		// Elevation-section / top-down previews turn this off — otherwise the
		// Fresnel + UV seam paints a dark bullseye over the sky.
		if (glass_enabled < 0.5 || glass_opacity < 0.02) {
			discard;
		}
		// Nearly invisible face-on, brightening to a soft bluish-white rim at
		// grazing angles (the classic cheap thin-glass fresnel look). Low
		// roughness + a touch of metallic gives the sun/sky a real specular
		// highlight so it reads as reflective glass rather than empty space.
		vec3 glass_tint = vec3(0.85, 0.93, 1.0);
		ALBEDO = glass_tint;
		ALPHA = clamp(0.025 + fresnel * 0.45, 0.0, 0.55) * clamp(glass_opacity, 0.0, 1.0);
		ROUGHNESS = 0.04;
		METALLIC = 0.2;
		SPECULAR = 0.9;
		RIM = 0.4;
		RIM_TINT = 0.7;
	} else {
		// ---- Below ground: opaque earth cross-section (terrarium cutaway) ----
		// The PNW soil profile (soi_strata.gdshaderinc). Face coordinates on
		// the sphere: arc length round the vertical axis, world height. Site
		// Plan's rim (`plain_soil`) keeps the profile but no flowing channels.
		vec2 rel = v_world_pos.xz - soi_center_radius.xz;
		vec2 face = vec2(atan(rel.y, rel.x) * soi_center_radius.w, v_world_pos.y);
		vec3 col = soi_soil(face, surface_y, soi_center_radius, TIME, soil_tex, soil_nrm,
				use_soil_tex, plain_soil > 0.5 ? 0.0 : 1.0);
		// Self-lit poster colors: the cross-section is a DIAGRAM, and letting
		// the scene light it washed the authored palette out twice over —
		// first a glossy aquifer mirrored the sky, then even fully matte the
		// bright sky ambient lifted dark navy to pastel. Emission renders the
		// colors exactly as written (values well under the daytime bloom cap),
		// while the living terrain above stays genuinely lit — the same
		// illustrated-cutaway-under-real-sky contrast as the reference.
		ALBEDO = vec3(0.0);
		EMISSION = col;
		ROUGHNESS = 1.0;
		METALLIC = 0.0;
		SPECULAR = 0.0;
		ALPHA = 1.0;
	}
}
