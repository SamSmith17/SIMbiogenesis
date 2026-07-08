global uniform vec4 soi_center_radius;
global uniform float soi_clip_enabled;

void soi_clip_fragment(vec3 world_pos) {
	if (soi_clip_enabled < 0.5) {
		return;
	}
	if (distance(world_pos, soi_center_radius.xyz) > soi_center_radius.w) {
		discard;
	}
}
