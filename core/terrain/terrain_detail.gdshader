shader_type spatial;

// Terrain drape with a high-resolution centre patch (ROADMAP Pillar 1).
// Shared implementation lives in `terrain_detail_body.gdshaderinc` so
// `terrain_detail_no_sdfgi.gdshader` can opt terrain out of SDFGI reception
// (`ambient_light_disabled`) without duplicating a single uniform or line of math.

render_mode cull_disabled, diffuse_lambert, specular_disabled;

#include "res://core/terrain/terrain_detail_body.gdshaderinc"
