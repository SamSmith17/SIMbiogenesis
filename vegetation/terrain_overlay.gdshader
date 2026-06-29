// Terrain vegetation overlay shader (Option 2).
//
// Replaces the imported BaseMaterial3D on each of the photogrammetric terrain's
// 51 surfaces. The albedo texture is preserved exactly. Where the per-pixel
// vegetation classifier fires (dark AND green/olive pixel), we:
//   - Increase roughness (vegetation is matte; bare sand/dirt is slightly
//     shinier). This is the primary visual cue.
//   - Slightly darken the albedo so the dark patches read as tufts rather than
//     a flat uniform tone.
//
// The NORMAL_MAP approach was removed: photogrammetric meshes have arbitrary
// tangent vectors per face so a world-space gradient applied in tangent-space
// produced incorrect lighting. Roughness alone is safer and more predictable.
//
// The speckle noise is driven by world-space XZ so adjacent atlas pages with
// different UV layouts join seamlessly.
shader_type spatial;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;

uniform float vegetation_luma_threshold : hint_range(0.0, 1.0) = 0.30;
uniform float vegetation_green_excess : hint_range(-0.2, 0.2) = 0.01;
uniform float vegetation_min_chroma : hint_range(0.0, 0.5) = 0.04;
uniform float fuzz_scale : hint_range(0.1, 20.0) = 4.0;
uniform float vegetation_roughness : hint_range(0.0, 1.0) = 0.92;
uniform float terrain_roughness : hint_range(0.0, 1.0) = 0.75;
// How much to darken vegetation pixels (0 = no change, 0.12 = 12% darker).
uniform float vegetation_albedo_tint : hint_range(0.0, 0.5) = 0.10;

varying vec3 v_world_pos;

float hash2d(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash2d(i);
	float b = hash2d(i + vec2(1.0, 0.0));
	float c = hash2d(i + vec2(0.0, 1.0));
	float d = hash2d(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Match the classifier in vegetation_scatter.gd._is_vegetation_color():
//   luma < luma_threshold  AND  g - max(r,b) > green_excess  AND  chroma >= min_chroma
float vegetation_mask(vec3 c) {
	float luma = dot(c, vec3(0.299, 0.587, 0.114));
	float hue_score = c.g - max(c.r, c.b);
	float chroma = max(max(c.r, c.g), c.b) - min(min(c.r, c.g), c.b);
	float luma_pass = smoothstep(vegetation_luma_threshold + 0.10,
	                             vegetation_luma_threshold - 0.05, luma);
	float hue_pass = smoothstep(vegetation_green_excess - 0.02,
	                            vegetation_green_excess + 0.05, hue_score);
	float chroma_pass = smoothstep(vegetation_min_chroma - 0.02,
	                               vegetation_min_chroma + 0.02, chroma);
	return luma_pass * hue_pass * chroma_pass;
}

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 base = texture(albedo_tex, UV).rgb;
	float mask = vegetation_mask(base);

	// World-space speckle noise breaks up the mask into individual tufts so
	// large vegetation patches don't read as a single uniform dark blob.
	float speckle = value_noise(v_world_pos.xz * fuzz_scale);

	// Slightly darken vegetation pixels; noise modulates the amount so it
	// reads as scattered clumps rather than a flat filter.
	float tint_amount = mask * (0.5 + speckle * 0.5) * vegetation_albedo_tint;
	ALBEDO = base * (1.0 - tint_amount);

	// Roughness is the main visual differentiator: matte vegetation vs
	// slightly shinier bare ground/sand.
	ROUGHNESS = mix(terrain_roughness, vegetation_roughness, mask);
	METALLIC = 0.0;
}
