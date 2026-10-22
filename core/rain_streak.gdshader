shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, fog_disabled;

// One raindrop as a motion streak along its own VELOCITY. The particle system
// aligns each drop's Y axis to its velocity (particle_flag_align_y), so a drop
// blown sideways by the wind draws slanted and a drop in still air falls
// straight down. The quad turns about that axis to face the camera.
// Width and length come from PrecipitationVfx (drop diameter, and the distance
// the drop covers in a camera-shutter-like exposure).

uniform float streak_width = 0.01;    // metres
uniform float streak_length = 0.25;   // metres
uniform vec4 drop_color : source_color = vec4(0.82, 0.86, 0.92, 0.5);

varying float v_edge;
varying float v_along;

void vertex() {
	vec3 center = MODEL_MATRIX[3].xyz;
	vec3 axis = MODEL_MATRIX[1].xyz;
	float al = length(axis);
	axis = al > 0.00001 ? axis / al : vec3(0.0, -1.0, 0.0);
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 to_cam = cam - center;
	float tl = length(to_cam);
	to_cam = tl > 0.00001 ? to_cam / tl : vec3(0.0, 0.0, 1.0);
	vec3 side = cross(axis, to_cam);
	float sl = length(side);
	side = sl > 0.00001 ? side / sl : vec3(1.0, 0.0, 0.0);
	// QuadMesh of size 1: VERTEX.xy in [-0.5, 0.5].
	vec3 world = center + side * VERTEX.x * streak_width + axis * VERTEX.y * streak_length;
	v_edge = VERTEX.x * 2.0;
	v_along = VERTEX.y + 0.5;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
}

void fragment() {
	// Soft across the streak; brightest at the head, fading along the tail.
	float edge = 1.0 - clamp(abs(v_edge), 0.0, 1.0);
	float tail = mix(0.25, 1.0, clamp(v_along, 0.0, 1.0));
	ALBEDO = drop_color.rgb;
	ALPHA = drop_color.a * edge * tail;
}
