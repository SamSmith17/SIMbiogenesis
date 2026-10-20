// Shared lighting helpers for the vegetation shaders (foliage, leaf_canopy,
// bark, grass). Three global uniforms, declared in project.godot
// [shader_globals]:
//   veg_fill        0 in first person. The graph's 3D lenses and the
//                   full-screen globe raise it (~0.3) while they render: a
//                   self-lit fill so canopies read at preview distance even
//                   when the player runs a very low world ambient (0.05 was
//                   printing shadowed crowns black next to the self-lit soil).
//   veg_haze_mul    1 in first person; previews set 0. The distance haze is
//                   tuned for eye level and painted every crown 200 m+ out a
//                   flat unlit average colour from the preview cameras.
//   veg_sky_fill    the WORLD's shade fill, pushed by Main every frame:
//                   DaylightModel sky_light x VEG_SHADE_FILL x the share of
//                   the scene ambient the player has turned OFF. Foliage in
//                   shade under open sky is lit by the sky dome (~15-25 % of
//                   full sun); with ambient_energy_mult near 0 every
//                   self-shadowed card got nothing and crowns printed black.
//                   0 at night and 0 at the default ambient (1.0).
//   veg_saturation  foliage saturation before lighting (default 1.1). The
//                   leaf palettes are authored in sRGB and darkened by the
//                   linear conversion; a little saturation keeps greens green
//                   rather than olive-grey after tonemapping.

global uniform float veg_fill;
global uniform float veg_haze_mul;
global uniform float veg_sky_fill;
global uniform float veg_saturation;

// Godot ALREADY turns NORMAL toward the camera on back faces under
// cull_disabled (probed: view-space NORMAL.z is +1 from both sides of a
// quad). The vegetation shaders used to flip it again for !FRONT_FACING,
// which pointed every back face AWAY from the camera and lit it as if from
// behind — the reason half of each leaf card, bough and bark card read near
// black. Don't flip; a mild face factor keeps backs a touch darker.
const float VEG_BACK_FACE = 0.85;

// NORMAL in fragment() is VIEW space; the sun direction and "up" are WORLD.
vec3 veg_world_normal(vec3 view_n, mat4 inv_view) {
	return normalize((inv_view * vec4(view_n, 0.0)).xyz);
}

// The self-lit fill to add: the preview's fill, else the world shade fill.
float veg_fill_amount() {
	return max(veg_fill, veg_sky_fill);
}

vec3 veg_saturate(vec3 c, float s) {
	float l = dot(c, vec3(0.299, 0.587, 0.114));
	return max(mix(vec3(l), c, s), vec3(0.0));
}

// Select-tool species glow. The V toolbar's Select hover sets this on every
// batch of the hovered tree's species (TerrainLoader.set_veg_species_glow —
// one value per MultiMeshInstance3D, so a whole species lights at once with
// no per-tree markers), and 0 everywhere else. Subtle on purpose: a warm
// lift so the eye finds the others, not a recolour.
instance uniform float veg_hl = 0.0;
const vec3 VEG_HL_COLOR = vec3(1.0, 0.78, 0.32);

vec3 veg_hl_albedo(vec3 a) {
	return mix(a, VEG_HL_COLOR * 0.6, veg_hl * 0.22);
}

vec3 veg_hl_emission() {
	return VEG_HL_COLOR * (veg_hl * 0.16);
}
