class_name RenderStyleEffect
extends CompositorEffect
## The visual-style post pass (RenderStyle): one compute shader, two dispatches
## after the transparent pass (HDR, before tonemapping, so it sees water, glass
## and particles too):
##   1. copy the colour buffer into a scratch texture;
##   2. read the scratch (neighbours) and write the colour buffer:
##      - painterly smoothing: a smooth 4-sector Kuwahara filter (Papari et al.
##        2007 weighting, q = 8), which flattens texture detail into painted
##        patches while keeping edges;
##      - cel light: the log-luminance quantised into bands a few stops wide,
##        with a soft edge, and the lighting range compressed toward mid grey;
##      - colour grade: saturation + vibrance, a cyan push on the daylight sky,
##        split toning (cool shadows, warm highlights);
##      - ink outlines: the depth buffer's second difference (zero on any
##        plane, since reverse-Z depth ∝ 1/z is affine in screen space, so a
##        grazing floor never draws a line) drawn on the NEAR side of an edge,
##        plus crease lines from the normal buffer up close, faded by distance.
##
##      - the finish: a halftone dot screen in the shadows, lifted blacks, a
##        paper colour, paper texture or moving film grain, a vignette (these
##        extra numbers ride a 48-byte uniform buffer: the push constant is
##        full at 128 bytes).
##
## Parameters come from RenderStyleDriver on the main thread (set_params) and
## are read on the render thread under a mutex.

const CONTEXT := &"render_style"
const SCRATCH := &"scratch"

const SHADER := """
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D src_img;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D dst_img;
layout(set = 0, binding = 2) uniform sampler2D depth_tex;
layout(set = 0, binding = 3) uniform sampler2D normal_tex;
layout(set = 0, binding = 4, std140) uniform Extra {
	vec4 e0; // lift, grain, grain_anim (0 paper, 1 film), vignette
	vec4 e1; // paper_tint.rgb, paper_mix
	vec4 e2; // halftone, halftone_px, time (s), unused
} E;

layout(push_constant, std430) uniform Params {
	vec4 p0; // size.x, size.y, mode (0 copy, 1 style, 2 style without crease lines), z near
	vec4 p1; // band_mix, band_stops, band_soft, light_compress
	vec4 p2; // kuwahara_px, outline_mix, outline_px, outline_dark
	vec4 p3; // outline_depth_t, outline_normal_t, fade_start, fade_end
	vec4 p4; // saturation, vibrance, sky_saturation, exposure
	vec4 p5; // shadow_tint.rgb, split_mix
	vec4 p6; // highlight_tint.rgb, sky_cyan
	vec4 p7; // outline_tint.rgb, green_push
} P;

float lum(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

vec3 rgb2hsv(vec3 c) {
	vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
	vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
	vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

vec3 hsv2rgb(vec3 c) {
	vec3 p = abs(fract(c.xxx + vec3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
	return c.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

ivec2 cl(ivec2 q, ivec2 s) { return clamp(q, ivec2(0), s - ivec2(1)); }

float dep(ivec2 q, ivec2 s) { return texelFetch(depth_tex, cl(q, s), 0).r; }

vec3 nrm(ivec2 q, ivec2 s) {
	vec3 n = texelFetch(normal_tex, cl(q, s), 0).xyz * 2.0 - 1.0;
	return n / max(length(n), 1e-5);
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), u.x),
		mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}

vec3 kuwahara(ivec2 uv, ivec2 size, int r) {
	vec3 m0 = vec3(0.0), m1 = vec3(0.0), m2 = vec3(0.0), m3 = vec3(0.0);
	vec4 s1 = vec4(0.0);
	vec4 s2 = vec4(0.0);
	for (int j = -r; j <= r; j++) {
		for (int i = -r; i <= r; i++) {
			vec3 c = imageLoad(src_img, cl(uv + ivec2(i, j), size)).rgb;
			float l = lum(c);
			l = l / (1.0 + l);
			if (i <= 0 && j <= 0) { m0 += c; s1.x += l; s2.x += l * l; }
			if (i >= 0 && j <= 0) { m1 += c; s1.y += l; s2.y += l * l; }
			if (i <= 0 && j >= 0) { m2 += c; s1.z += l; s2.z += l * l; }
			if (i >= 0 && j >= 0) { m3 += c; s1.w += l; s2.w += l * l; }
		}
	}
	float n = float((r + 1) * (r + 1));
	vec4 mean = s1 / n;
	vec4 var4 = max(s2 / n - mean * mean, vec4(0.0));
	// Weights relative to the smoothest sector, so they never all vanish
	// (a white tent on grass made every sector "rough" and the absolute
	// weights underflowed to a black pixel).
	vec4 sig = sqrt(var4) * 255.0;
	float s0 = min(min(sig.x, sig.y), min(sig.z, sig.w));
	vec4 rel = sig / (s0 + 4.0);
	vec4 w = 1.0 / (1.0 + pow(rel, vec4(8.0)));
	float ws = w.x + w.y + w.z + w.w;
	return (m0 * w.x + m1 * w.y + m2 * w.z + m3 * w.w) / (n * ws);
}

void main() {
	ivec2 size = ivec2(P.p0.xy);
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	if (uv.x >= size.x || uv.y >= size.y) {
		return;
	}
	vec4 src = imageLoad(src_img, uv);
	if (P.p0.z < 0.5) {
		imageStore(dst_img, uv, src);
		return;
	}
	float res = float(size.y) / 1080.0;
	float d = dep(uv, size);
	bool sky = d < 1e-7;
	float zn = max(P.p0.w, 1e-4);
	float z = sky ? 1e9 : zn / d;
	vec3 c = src.rgb;

	// Painterly smoothing.
	int r = int(min(P.p2.x * res, 6.0) + 0.5);
	if (r > 0) {
		c = kuwahara(uv, size, r);
	}

	// Cel light: compress the lighting range, then band it.
	float expo = max(P.p4.w, 1e-3);
	float L = max(lum(c), 1e-7);
	float lg = log2(L * expo / 0.18);
	if (!sky) {
		float lg2 = lg * (1.0 - P.p1.w);
		float S = P.p1.y;
		float x = lg2 / S;
		float f = fract(x);
		float sm = smoothstep(0.5 - P.p1.z, 0.5 + P.p1.z, f);
		float q = (floor(x) + sm) * S;
		// Bands belong to near things; far ground is painted, not banded
		// (banding a distant aerial photo reads as camouflage).
		float band = P.p1.x * (1.0 - 0.8 * smoothstep(P.p3.z, P.p3.w, z));
		lg2 = mix(lg2, q, band);
		c *= exp2(lg2 - lg);
		lg = lg2;
	}

	// Colour grade.
	float L2 = lum(c);
	float mx = max(c.r, max(c.g, c.b));
	float mn = min(c.r, min(c.g, c.b));
	float s = mx > 1e-6 ? (mx - mn) / mx : 0.0;
	float vib = P.p4.y * (1.0 - s);
	if (!sky) {
		// Distant haze is a desaturated blue: vibrance would turn it navy.
		float hue = rgb2hsv(c).x;
		vib *= 1.0 - smoothstep(0.50, 0.55, hue) * (1.0 - smoothstep(0.70, 0.76, hue));
	}
	float satk = (sky ? P.p4.z : P.p4.x) * (1.0 + vib);
	// Deep shadow keeps its own colour.
	if (!sky) {
		satk = 1.0 + (satk - 1.0) * smoothstep(-6.0, -2.5, lg);
	}
	c = max(vec3(L2) + (c - vec3(L2)) * satk, vec3(0.0));
	if (sky) {
		float blueish = clamp((c.b - c.r) / max(c.b, 1e-5) * 2.0, 0.0, 1.0);
		vec3 cy = c * vec3(0.8, 1.0, 1.12);
		cy *= L2 / max(lum(cy), 1e-6);
		c = mix(c, cy, P.p6.w * blueish);
	} else {
		// Olive / yellow-green (hue ~45-85 deg) turned toward a fresh green.
		if (P.p7.w > 0.001) {
			vec3 hsv = rgb2hsv(c);
			float wgt = smoothstep(0.10, 0.16, hsv.x) * (1.0 - smoothstep(0.22, 0.27, hsv.x));
			// Dull olive turns; bright autumn yellow keeps its colour.
			wgt *= smoothstep(0.08, 0.25, hsv.y) * (1.0 - smoothstep(0.5, 0.75, hsv.y));
			hsv.x += 0.09 * P.p7.w * wgt;
			hsv.y = min(hsv.y * (1.0 + 0.15 * P.p7.w * wgt), 1.0);
			c = hsv2rgb(hsv);
		}
		float t = smoothstep(-3.0, 1.0, lg);
		vec3 tint = mix(P.p5.rgb, P.p6.rgb, t);
		tint /= max(lum(tint), 1e-4);
		c = mix(c, c * tint, P.p5.w);
	}

	// Ink outlines.
	if (!sky && P.p2.y > 0.001) {
		int w = max(1, int(P.p2.z * res + 0.5));
		float dl = dep(uv + ivec2(-w, 0), size);
		float dr = dep(uv + ivec2(w, 0), size);
		float du = dep(uv + ivec2(0, -w), size);
		float dd = dep(uv + ivec2(0, w), size);
		float lx = max(2.0 * d - dl - dr, 0.0) / d;
		float ly = max(2.0 * d - du - dd, 0.0) / d;
		float t = P.p3.x;
		float ex = smoothstep(t, t * 2.5, lx);
		float ey = smoothstep(t, t * 2.5, ly);
		float e = max(ex, ey);
		// A thing only a few pixels across is edge in both directions at
		// once: draw it in its own colour, never as a black dot.
		e *= 1.0 - 0.75 * min(ex, ey);
		if (P.p0.z < 1.5) {
			vec3 nc = nrm(uv, size);
			float k = min(min(dot(nc, nrm(uv + ivec2(-w, 0), size)), dot(nc, nrm(uv + ivec2(w, 0), size))),
					min(dot(nc, nrm(uv + ivec2(0, -w), size)), dot(nc, nrm(uv + ivec2(0, w), size))));
			float nfade = 1.0 - smoothstep(P.p3.z * 0.4, P.p3.z, z);
			e = max(e, smoothstep(P.p3.y, P.p3.y + 0.2, 1.0 - k) * nfade);
		}
		float fade = 1.0 - smoothstep(P.p3.z, P.p3.w, z);
		e *= fade * P.p2.y;
		c = mix(c, c * P.p2.w * P.p7.rgb, e);
	}

	// Halftone: shadows printed as a 45-degree dot screen (ink dots on paper).
	if (!sky && E.e2.x > 0.001) {
		float cell = max(E.e2.y * res, 2.0);
		vec2 q = mat2(0.7071, -0.7071, 0.7071, 0.7071) * (vec2(uv) + 0.5) / cell;
		float dist = length(fract(q) - 0.5) * 2.0;
		float dark = clamp(-lg / 4.0, 0.0, 1.0);
		float rad = sqrt(dark) * 1.05;
		float dotm = 1.0 - smoothstep(rad - 0.12, rad + 0.12, dist);
		float mask = smoothstep(-0.3, -1.6, lg) * E.e2.x;
		c = mix(c, c * mix(1.9, 0.1, dotm), mask);
	}

	// Lifted blacks: a floor of paper-coloured light, scaled to the exposure.
	float midg = 0.18 / expo;
	vec3 paper = E.e1.rgb / max(lum(E.e1.rgb), 1e-4);
	if (E.e0.x > 0.001) {
		c += E.e0.x * midg * 0.5 * paper;
	}
	// Paper colour.
	c = mix(c, c * paper, E.e1.w);
	// Grain: paper fibre and pigment blotches (still) or film grain (moving).
	if (E.e0.y > 0.001) {
		float n;
		if (E.e0.z > 0.5) {
			n = hash12(vec2(uv) + floor(E.e2.z * 24.0) * vec2(17.0, 59.0));
		} else {
			vec2 pv = vec2(uv) / res;
			n = 0.55 * vnoise(pv / 2.2) + 0.30 * vnoise(pv / 11.0) + 0.15 * vnoise(pv / 45.0);
		}
		c *= 1.0 + E.e0.y * (n - 0.5) * 2.0;
	}
	// Vignette.
	if (E.e0.w > 0.001) {
		vec2 sv = (vec2(uv) + 0.5) / vec2(size) - 0.5;
		sv.x *= float(size.x) / float(size.y);
		c *= 1.0 - E.e0.w * smoothstep(0.35, 1.0, length(sv) * 1.3);
	}
	imageStore(dst_img, uv, vec4(max(c, vec3(0.0)), src.a));
}
"""

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _sampler: RID
var _mutex := Mutex.new()
var _floats := PackedFloat32Array()
var _extra := PackedFloat32Array()
var _ubo: RID
var _use_normals := true
var _compile_error := ""


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	needs_normal_roughness = true
	access_resolved_color = true
	access_resolved_depth = true
	enabled = false
	_floats.resize(28)
	_extra.resize(12)
	RenderingServer.call_on_render_thread(_init_compute)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _shader.is_valid():
			RenderingServer.free_rid(_shader)
		if _sampler.is_valid():
			RenderingServer.free_rid(_sampler)
		if _ubo.is_valid():
			RenderingServer.free_rid(_ubo)


## The 28 floats from RenderStyle.post_floats, the 12 from
## RenderStyle.extra_floats; use_normals = crease lines.
func set_params(floats: PackedFloat32Array, use_normals: bool = true,
		extra: PackedFloat32Array = PackedFloat32Array()) -> void:
	_mutex.lock()
	_floats = floats.duplicate()
	_use_normals = use_normals
	if extra.size() == 12:
		_extra = extra.duplicate()
	_mutex.unlock()


func ready_to_render() -> bool:
	return _pipeline.is_valid()


func compile_error() -> String:
	return _compile_error


func _init_compute() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return
	var src := RDShaderSource.new()
	src.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	src.source_compute = SHADER
	var spirv := _rd.shader_compile_spirv_from_source(src)
	if spirv == null or not spirv.compile_error_compute.is_empty():
		_compile_error = spirv.compile_error_compute if spirv != null else "no SPIR-V"
		push_error("RenderStyleEffect: shader did not compile: %s" % _compile_error)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		_compile_error = "shader_create_from_spirv failed"
		return
	_pipeline = _rd.compute_pipeline_create(_shader)
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(ss)
	var zero := PackedByteArray()
	zero.resize(48)
	_ubo = _rd.uniform_buffer_create(48, zero)


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if _rd == null or not _pipeline.is_valid() or not _ubo.is_valid() or callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		return
	var rsb := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var rsd := render_data.get_render_scene_data() as RenderSceneDataRD
	if rsb == null or rsd == null:
		return
	var size := rsb.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	var views := rsb.get_view_count()
	if rsb.has_texture(CONTEXT, SCRATCH):
		var fmt := rsb.get_texture_format(CONTEXT, SCRATCH)
		if fmt == null or fmt.width != size.x or fmt.height != size.y or fmt.array_layers != views:
			rsb.clear_context(CONTEXT)
	if not rsb.has_texture(CONTEXT, SCRATCH):
		rsb.create_texture(CONTEXT, SCRATCH, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT,
			RenderingDevice.TEXTURE_SAMPLES_1, size, views, 1, true, false)

	var near := 0.05
	var proj := rsd.get_cam_projection()
	var zn := proj.get_z_near()
	if is_finite(zn) and zn > 0.0:
		near = zn

	_mutex.lock()
	var floats := _floats.duplicate()
	var use_normals := _use_normals
	var extra := _extra.duplicate()
	_mutex.unlock()
	extra[10] = float(Time.get_ticks_msec() % 3600000) / 1000.0
	var extra_bytes := extra.to_byte_array()
	_rd.buffer_update(_ubo, 0, extra_bytes.size(), extra_bytes)
	var head := PackedFloat32Array([float(size.x), float(size.y), 0.0, near])
	var copy_pc := head.duplicate()
	copy_pc.append_array(floats)
	var copy_bytes := copy_pc.to_byte_array()

	var gx := ceili(size.x / 8.0)
	var gy := ceili(size.y / 8.0)
	var has_normals := rsb.has_texture(&"forward_clustered", &"normal_roughness")
	for view in views:
		var color := rsb.get_color_layer(view)
		var depth := rsb.get_depth_layer(view)
		var normal := depth
		if has_normals:
			normal = rsb.get_texture_slice(&"forward_clustered", &"normal_roughness", view, 0, 1, 1)
		var scratch := rsb.get_texture_slice(CONTEXT, SCRATCH, view, 0, 1, 1)
		if not (color.is_valid() and depth.is_valid() and scratch.is_valid()):
			continue
		var set_copy := UniformSetCacheRD.get_cache(_shader, 0, [
			_image(0, color), _image(1, scratch), _tex(2, depth), _tex(3, normal), _buffer(4)])
		var set_style := UniformSetCacheRD.get_cache(_shader, 0, [
			_image(0, scratch), _image(1, color), _tex(2, depth), _tex(3, normal), _buffer(4)])
		var style_pc := copy_pc.duplicate()
		style_pc[2] = 1.0 if (use_normals and has_normals) else 2.0
		var pc_bytes := style_pc.to_byte_array()
		var cl := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
		_rd.compute_list_bind_uniform_set(cl, set_copy, 0)
		_rd.compute_list_set_push_constant(cl, copy_bytes, copy_bytes.size())
		_rd.compute_list_dispatch(cl, gx, gy, 1)
		_rd.compute_list_end()
		cl = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
		_rd.compute_list_bind_uniform_set(cl, set_style, 0)
		_rd.compute_list_set_push_constant(cl, pc_bytes, pc_bytes.size())
		_rd.compute_list_dispatch(cl, gx, gy, 1)
		_rd.compute_list_end()


func _image(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(rid)
	return u


func _buffer(binding: int) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	u.binding = binding
	u.add_id(_ubo)
	return u


func _tex(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(_sampler)
	u.add_id(rid)
	return u
