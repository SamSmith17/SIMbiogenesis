shader_type spatial;

// Terrain drape variant with built-in ambient/SDFGI disabled ("SDFGI on terrain"
// unchecked in Settings → Lighting): structures, vehicles and props still receive
// full SDFGI (including bounce FROM the terrain's GI_MODE_STATIC mesh), while the
// ground itself shades with smooth hemispherical sky ambient (`terrain_sky_ambient`).

render_mode cull_disabled, diffuse_lambert, specular_disabled, ambient_light_disabled;

#define TERRAIN_CUSTOM_AMBIENT 1
#include "res://core/terrain/terrain_detail_body.gdshaderinc"
