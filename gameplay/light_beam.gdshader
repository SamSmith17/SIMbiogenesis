shader_type spatial;
// The visible shaft of a moving head's beam, or one laser beam, as it would
// read through festival haze (PlacedMoverLight). A cone (or thin cylinder)
// along the mesh's +Y, drawn additively: brightest on the axis and near the
// lens, fading with distance along the beam and toward the cone's edge.
//
// Real beams are only visible in haze/fog; in scenes with volumetric fog the
// SpotLight3D's own `light_volumetric_fog_energy` adds the true scattering on
// top of this. `haze` is the fixture's "beam in haze" knob, `night` the
// day/night visibility (a beam is nearly invisible at noon).
//
// fog_disabled for the camp-glow reason: Godot fogs additive unshaded quads
// and turns zero-light geometry into fog-coloured shapes.
//
// MIN WIDTH: a laser is ~3 mm across and would vanish below a pixel at any
// range; vertices are pushed out radially so the beam never gets thinner than
// `min_width_rad` of view angle (like the camp cards' constant apparent size).
render_mode unshaded, cull_disabled, blend_add, depth_draw_never, shadows_disabled, fog_disabled;

// Cosmetic clock (SimFxRate): advances with the sim, time-lapsed and
// capped, frozen dead while paused. Replaces TIME, which never stops.
global uniform float fx_time_lights;

uniform vec3 beam_color : source_color = vec3(1.0);
uniform float intensity = 1.0;
uniform float haze = 0.5;
uniform float night = 1.0;
// The mesh is a UNIT cone/cylinder (height 1, radius 1) that the fixture scales
// to (R, L, R); this is R, so the vertex stage can measure the real radius.
uniform float radial_scale = 1.0;
// Falloff along the beam (higher = shorter visible shaft).
uniform float falloff = 1.6;
uniform float min_width_rad = 0.0015;
uniform float shimmer = 0.15;

varying float v_along;
varying vec3 v_world;

void vertex() {
	// Unit CylinderMesh is centred: y in [-0.5, 0.5], -0.5 = the lens end.
	v_along = clamp(VERTEX.y + 0.5, 0.0, 1.0);
	float r = length(VERTEX.xz) * radial_scale;
	vec4 view = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	float need = length(view.xyz) * min_width_rad;
	if (r > 1e-7 && r < need) {
		VERTEX.xz *= need / r;
	}
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.yzx + 33.33);
	return fract((p.x + p.y) * p.z);
}

void fragment() {
	// Edge-on surfaces are the cone's rim; facing surfaces its core.
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float core = pow(facing, 1.5);
	// max(): the interpolated v_along overshoots 1.0 by a hair at the far end,
	// and pow() of a negative base is NaN — which the glow pass spreads into a
	// bright square with a black centre where every beam ends.
	float along = pow(max(1.0 - v_along, 0.0), falloff);
	// Slow drifting haze grain (world-space, so it does not crawl with the beam).
	float grain = mix(1.0, 0.6 + 0.8 * hash31(floor(v_world * 0.7 + vec3(fx_time_lights * 0.15))), shimmer);
	vec3 c = beam_color * intensity * haze * night * core * along * grain;
	ALBEDO = clamp(c, vec3(0.0), vec3(64.0));
}
