shader_type spatial;
// The weather shell just above the ground: clouds from an infrared mosaic
// (equirect, gray + alpha: higher gray = colder = higher cloud top, mapped
// to cover through gray_lo..gray_hi) lit by the Sun, and rain (an RGBA
// colour-ramped image, transparent where dry) drawn over them. Both fade out
// as the camera comes down below the cloud deck. The equirect seam at ±180°
// samples with the gradient of a seam-free copy of u, so mip selection does
// not draw a line down the antimeridian.
render_mode unshaded, blend_mix, cull_back, depth_draw_never, shadows_disabled;
#include "res://scenes/ui/globe/globe_eq.gdshaderinc"

uniform sampler2D cloud_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2D rain_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform bool has_clouds = false;
uniform bool has_rain = false;
uniform float cloud_opacity = 0.92;
uniform float rain_opacity = 0.85;
uniform float gray_lo = 0.30;
uniform float gray_hi = 0.66;
uniform vec3 sun_dir = vec3(0.0, 0.0, 1.0);

varying vec3 w_pos;

void vertex() {
	w_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 n = normalize(w_pos);
	float cam_alt = length(CAMERA_POSITION_WORLD) - 1.0;
	float ndl = dot(n, normalize(sun_dir));
	float lit = smoothstep(-0.12, 0.2, ndl);
	vec3 col = vec3(0.0);
	float a = 0.0;
	if (has_clouds) {
		vec4 c = globe_eq_sample(cloud_tex, n);
		float cover = smoothstep(gray_lo, gray_hi, c.r) * c.a;
		float fade = smoothstep(0.003, 0.012, cam_alt);
		vec3 cc = mix(vec3(0.045, 0.05, 0.07), vec3(1.0), lit);
		cc += vec3(0.4, 0.15, 0.03) * exp(-(ndl / 0.08) * (ndl / 0.08));
		col = cc;
		a = cover * cloud_opacity * fade;
	}
	if (has_rain) {
		vec4 r = globe_eq_sample(rain_tex, n);
		float ra = r.a * rain_opacity * smoothstep(0.0016, 0.005, cam_alt);
		vec3 rc = r.rgb * mix(0.55, 1.0, lit);
		col = mix(col * a, rc, ra) / max(a + ra * (1.0 - a), 1e-4);
		a = a + ra * (1.0 - a);
	}
	ALBEDO = col;
	ALPHA = a;
}
