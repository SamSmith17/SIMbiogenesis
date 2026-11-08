shader_type spatial;
// The globe's ground: one Web Mercator tile per patch (or an ancestor's
// pixels through day_rect while the tile itself loads), lit by the real Sun
// (sun_dir, the globe frame), NASA Black Marble city lights on the night
// side, a warm band along the terminator and blue haze toward the limb.
// Unshaded: the globe's own World3D has no lights; the shading is here.
render_mode unshaded, cull_back, depth_draw_opaque;
#include "res://scenes/ui/globe/globe_eq.gdshaderinc"

uniform sampler2D day_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D night_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 day_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec4 night_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform bool has_day = false;
uniform bool has_night = false;
uniform bool solid = false;
uniform vec3 solid_color : source_color = vec3(0.86, 0.90, 0.95);
// Polar cap (past the Mercator edge). UV is polar stereographic, the pole
// at the centre. The outer cap_edge degrees blend into solid_color, which
// the view sets from the last Mercator row so the join is not a ring.
uniform sampler2D cap_tex : source_color, filter_linear, repeat_disable;
uniform bool has_cap = false;
uniform float cap_edge = 1.5;
uniform vec3 ocean_color : source_color = vec3(0.03, 0.07, 0.15);
uniform vec3 sun_dir = vec3(0.0, 0.0, 1.0);
uniform float night_gain = 1.8;
uniform float ambient = 0.008;
uniform float haze = 0.55;
// Cloud shadows: the weather shell's infrared clouds (globe_clouds) darken
// the sunlit ground under them; gone close to the ground (blurry blobs).
uniform sampler2D cloud_tex : filter_linear_mipmap, repeat_enable;
uniform bool has_cloud_shadow = false;
// A world's own terrain photos (GlobeDrape): d0 = the wide drape, d1 = the
// fine site patch, drawn over the tiles with a feathered edge. Positions go
// through d = lat - centre and a Mercator series (k), never an absolute
// Mercator difference (float32 cannot hold one).
uniform sampler2D d0_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform bool has_d0 = false;
uniform vec2 d0_c;
uniform vec3 d0_k;
uniform vec4 d0_box;
uniform sampler2D d1_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform bool has_d1 = false;
uniform vec2 d1_c;
uniform vec3 d1_k;
uniform vec4 d1_box;

vec2 drape_uv(vec3 n, vec2 c, vec3 k, vec4 box) {
	float d = asin(clamp(n.y, -1.0, 1.0)) - c.x;
	float dl = atan(n.x, n.z) - c.y;
	dl -= 6.28318530718 * round(dl / 6.28318530718);
	float s = ((k.z * d + k.y) * d + k.x) * d;
	return vec2((dl - box.z) / (box.w - box.z), (box.x - s) / (box.x - box.y));
}

float drape_w(vec2 uv) {
	float e = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
	return smoothstep(0.0, 0.035, e);
}
uniform float gray_lo = 0.30;
uniform float gray_hi = 0.66;
// A data layer over the ground (Globe mode): an equirect texture, R = value
// / overlay_max, G = coverage (land). Mode 0 = bands at overlay_steps with
// dark outlines, 1 = a smooth ramp through the band colours. Drawn half lit
// so it still reads on the night side.
uniform sampler2D overlay_tex : filter_linear, repeat_enable;
uniform bool has_overlay = false;
uniform float overlay_alpha = 0.6;
uniform int overlay_mode = 0;
uniform float overlay_max = 8.0;
uniform vec4 overlay_colors[6];
uniform float overlay_steps[5];
// value = R * overlay_max + overlay_offset; the smooth ramp puts colour i at
// overlay_ramp_lo + i * overlay_ramp_step.
uniform float overlay_offset = 0.0;
uniform float overlay_ramp_lo = 1.5;
uniform float overlay_ramp_step = 1.0;
// Camera distance (radii) where the layer has faded in fully, and where it
// is gone: a 1-degree layer says nothing a photo does not from a few hundred
// km down, so it fades out well above the ground.
uniform float overlay_fade_far = 0.26;
uniform float overlay_fade_near = 0.047;

varying vec3 w_pos;

void vertex() {
	w_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 n = normalize(w_pos);
	vec3 day = ocean_color;
	if (solid) {
		day = solid_color;
		if (has_cap) {
			float lat_abs = abs(degrees(asin(clamp(n.y, -1.0, 1.0))));
			float dist = (90.0 - lat_abs) - (90.0 - 85.0511287798066);
			float rim = 1.0 - smoothstep(0.0, cap_edge, dist);
			day = mix(texture(cap_tex, UV).rgb, solid_color, rim);
		}
	} else if (has_day) {
		day = texture(day_tex, day_rect.xy + UV * day_rect.zw).rgb;
	}
	if (has_d0) {
		vec2 uv0 = drape_uv(n, d0_c, d0_k, d0_box);
		vec3 c0 = texture(d0_tex, clamp(uv0, 0.0, 1.0)).rgb;
		day = mix(day, c0, drape_w(uv0));
	}
	if (has_d1) {
		vec2 uv1 = drape_uv(n, d1_c, d1_k, d1_box);
		vec3 c1 = texture(d1_tex, clamp(uv1, 0.0, 1.0)).rgb;
		day = mix(day, c1, drape_w(uv1));
	}
	float ndl = dot(n, normalize(sun_dir));
	float lit = smoothstep(-0.14, 0.20, ndl);
	// The polar photo has no city lights. Without a higher floor it vanishes
	// in the polar night and the cap reads as a hole.
	float amb = (solid && has_cap) ? 0.10 : ambient;
	vec3 col = day * mix(amb, 1.0, lit) * (0.84 + 0.16 * clamp(ndl * 2.0, 0.0, 1.0));
	if (has_cloud_shadow) {
		vec4 cs = globe_eq_sample(cloud_tex, n);
		float cover = smoothstep(gray_lo, gray_hi, cs.r) * cs.a;
		col *= 1.0 - 0.5 * cover * lit * smoothstep(0.004, 0.02, length(CAMERA_POSITION_WORLD - w_pos));
	}
	float tw = exp(-(ndl / 0.07) * (ndl / 0.07));
	col += day * vec3(0.32, 0.11, 0.02) * tw * 0.6;
	if (has_night && !solid) {
		vec3 nl = texture(night_tex, night_rect.xy + UV * night_rect.zw).rgb;
		float dark = 1.0 - smoothstep(-0.16, 0.03, ndl);
		// Squared: keeps the lights, drops Black Marble's dim blue ground.
		col += nl * nl * night_gain * dark * vec3(1.0, 0.86, 0.62);
	}
	if (has_overlay) {
		// The 1° land mask drops the pole pixel, which left a pale disc in
		// the middle of a tinted Antarctica. Sample the cap as if it were
		// the last Mercator latitude, same longitude.
		vec3 n_ov = n;
		if (solid) {
			n_ov.y = clamp(n.y, -0.9961947, 0.9961947);
			n_ov = normalize(n_ov);
		}
		float lat_u = 0.5 - asin(clamp(n_ov.y, -1.0, 1.0)) / PI;
		float lon_u = atan(n_ov.x, n_ov.z) / (2.0 * PI) + 0.5;
		vec2 ov = texture(overlay_tex, vec2(lon_u, lat_u)).rg;
		float val = ov.r * overlay_max + overlay_offset;
		vec3 oc = overlay_colors[5].rgb;
		if (overlay_mode == 0) {
			for (int i = 4; i >= 0; i--) {
				if (val < overlay_steps[i]) { oc = overlay_colors[i].rgb; }
			}
			float edge = 1e3;
			float fw = max(fwidth(val), 1e-4);
			for (int i = 0; i < 5; i++) { edge = min(edge, abs(val - overlay_steps[i]) / fw); }
			oc *= mix(0.35, 1.0, smoothstep(0.6, 1.6, edge));
		} else {
			float x = clamp((val - overlay_ramp_lo) / overlay_ramp_step, 0.0, 5.0);
			int i0 = int(floor(min(x, 4.999)));
			oc = mix(overlay_colors[i0].rgb, overlay_colors[i0 + 1].rgb, x - float(i0));
		}
		// The data is coarse: it fades out as the camera comes down to where
		// the photo says more than the colour.
		float cam_d = length(CAMERA_POSITION_WORLD - w_pos);
		float a = overlay_alpha * smoothstep(0.25, 0.6, ov.g) * smoothstep(overlay_fade_near, overlay_fade_far, cam_d);
		// Quieter on the night side, so the lights and the aurora read.
		a *= mix(0.42, 1.0, lit);
		col = mix(col, oc * mix(0.38, 1.0, lit), a);
	}
	vec3 v = normalize(CAMERA_POSITION_WORLD - w_pos);
	float rim = pow(1.0 - clamp(dot(n, v), 0.0, 1.0), 3.0);
	float haze_lit = smoothstep(-0.25, 0.35, ndl);
	col = mix(col, vec3(0.36, 0.56, 0.95) * haze_lit, rim * haze);
	ALBEDO = col;
}
