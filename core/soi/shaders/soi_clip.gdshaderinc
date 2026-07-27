global uniform vec4 soi_center_radius;
global uniform float soi_clip_enabled;
/// Half-plane CT cutaway: xyz = plane point, w = enabled (0/1).
global uniform vec4 soi_section_plane;
/// Unit normal pointing toward the section camera (camera-side discarded).
global uniform vec4 soi_section_normal;

void soi_clip_fragment(vec3 world_pos) {
	if (soi_clip_enabled < 0.5) {
		return;
	}
	if (distance(world_pos, soi_center_radius.xyz) > soi_center_radius.w) {
		discard;
	}
	if (soi_section_plane.w > 0.5) {
		vec3 to_p = world_pos - soi_section_plane.xyz;
		if (dot(to_p, soi_section_normal.xyz) > 0.0) {
			discard;
		}
	}
}
