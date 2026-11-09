// Vapour and smoke INSIDE a vessel (TC Process Lab): billboard puffs that
// are cut off at the vessel's own inside surface, so nothing shows through
// the shell or above the lid however large a puff is. The container is given
// in the vessel's frame (m): a cylinder of radius `inner_r` from y = 0 to
// `top_y`, closed by a dome `dome_h` high (0 = a flat lid). A puff fades out
// over `soft` as it nears the wall or the lid (the gas pools under the lid
// and is drawn off, it does not pass through), and is not drawn on the far
// side of the section plane.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

uniform mat4 to_vessel;
uniform float inner_r = 0.15;
uniform float top_y = 0.5;
uniform float dome_h = 0.0;
uniform float dome_cap = 0.0;   // 0 = an elliptical head, 1 = a spherical cap
uniform float floor_y = 0.0;
uniform float soft = 0.025;
uniform vec4 cut_plane = vec4(0.0, 0.0, 1.0, 1.0e6);

varying vec3 v_world;

void vertex() {
	// Face the camera (what BILLBOARD_PARTICLES does in a StandardMaterial3D).
	mat4 mat_world = mat4(normalize(INV_VIEW_MATRIX[0]), normalize(INV_VIEW_MATRIX[1]),
		normalize(INV_VIEW_MATRIX[2]), MODEL_MATRIX[3]);
	mat_world = mat_world * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat_world;
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	v_world = (mat_world * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (dot(v_world, cut_plane.xyz) > cut_plane.w) {
		discard;
	}
	vec3 pv = (to_vessel * vec4(v_world, 1.0)).xyz;
	float r = length(pv.xz);
	float u = clamp(r / max(inner_r, 1.0e-4), 0.0, 1.0);
	float lid = top_y + dome_h * mix(sqrt(max(1.0 - u * u, 0.0)), 1.0 - u * u, dome_cap);
	// Distance inside the container (negative = outside).
	float inside = min(min(inner_r - r, lid - pv.y), pv.y - floor_y);
	if (inside <= 0.0) {
		discard;
	}
	vec2 c = UV - vec2(0.5);
	float puff = smoothstep(0.5, 0.12, length(c));
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a * puff * smoothstep(0.0, soft, inside);
}
