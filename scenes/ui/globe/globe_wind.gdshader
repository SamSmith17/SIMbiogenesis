shader_type spatial;
// Wind streamlines on a shell above the clouds (GlobeWindField line list).
// UV.x = distance along the line (degrees), UV.y = a per-line phase,
// COLOR.r = speed / 40 m/s. Each line is faint all along with bright comets
// running down it at a rate set by the wind speed; the colour goes from a
// cool grey-blue in light air through green and yellow to magenta in a gale.
// Additive, so dense flow reads brighter; fades out near the ground.
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform float base_alpha = 0.16;
uniform float comet_alpha = 0.9;
uniform float period_deg = 7.0;
// Degrees per second the comets travel for each m/s of wind.
uniform float rate = 0.35;


varying vec3 w_pos;
varying float v_speed;

void vertex() {
	w_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_speed = COLOR.r * 40.0;
}

vec3 speed_color(float s) {
	vec3 c = mix(vec3(0.55, 0.70, 0.95), vec3(0.45, 0.95, 0.55), smoothstep(2.0, 7.0, s));
	c = mix(c, vec3(1.0, 0.92, 0.35), smoothstep(7.0, 13.0, s));
	c = mix(c, vec3(1.0, 0.45, 0.25), smoothstep(13.0, 20.0, s));
	return mix(c, vec3(1.0, 0.35, 0.9), smoothstep(20.0, 30.0, s));
}

void fragment() {
	float cam_alt = length(CAMERA_POSITION_WORLD) - 1.0;
	float fade = smoothstep(0.0012, 0.006, cam_alt);
	float t = fract(UV.y - (UV.x - TIME * rate * v_speed) / period_deg);
	float comet = pow(t, 6.0);
	vec3 col = speed_color(v_speed);
	ALBEDO = col * (base_alpha + comet * comet_alpha) * fade;
	ALPHA = 1.0;
}
