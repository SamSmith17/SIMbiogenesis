shader_type canvas_item;
render_mode unshaded;

// One corner-pinned quad of ProjectionWarp. The ColorRect covers the whole
// warp control; each pixel is mapped back through the inverse homography to
// the unit square of its quad, then into the quad's region of the source.
// Pixels outside the quad (or behind the projective horizon) are discarded.

uniform sampler2D src : filter_linear, repeat_disable;
uniform mat3 h_inv;            // control pixels -> unit square (ProjectionWarp.homography().inverse())
uniform vec4 uv_rect = vec4(0.0, 0.0, 1.0, 1.0);   // the quad's source region: x, y, w, h

varying vec2 v_px;

void vertex() {
	v_px = VERTEX;
}

void fragment() {
	vec3 q = h_inv * vec3(v_px, 1.0);
	if (q.z <= 0.0) {
		discard;
	}
	vec2 uv = q.xy / q.z;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		discard;
	}
	COLOR = vec4(texture(src, uv_rect.xy + uv * uv_rect.zw).rgb, 1.0);
}
