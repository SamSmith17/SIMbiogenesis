// Shared seasonal leaf law (veg overhaul Phase 6).
//
// The three canopy tiers — leaf-shell NEAR (leaf_canopy.gdshader), card FAR
// (foliage.gdshader) and the baked impostor quad (veg_impostor.gdshader) — each
// thinned and recoloured foliage its own way, so a tree visibly changed season
// as it crossed a ring boundary: the shells shrank their leaves, the cards
// discarded on a SCREEN-space dither (which shimmers when the camera moves),
// and the impostor picked one flat autumn colour per 24 m cell. All of the
// phenology lives here now; a tier supplies only its own per-leaf key and its
// own foliage mask.

// Leaf loss is removal, not shrinkage: a bare deciduous crown has fewer leaves,
// not smaller ones. The survivors do curl a little, which is what this floor
// leaves room for.
const float VEG_LEAF_MIN_SIZE = 0.55;

float veg_leaf_loss(float coverage, float decid) {
	return clamp((1.0 - coverage) * decid, 0.0, 1.0);
}

float veg_leaf_size_mul(float coverage, float decid) {
	return mix(1.0, mix(VEG_LEAF_MIN_SIZE, 1.0, coverage), decid);
}

float veg_phenology_hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

// True when this leaf has fallen. `key` must be stable in the tree's OWN frame
// (UV grid + a per-instance seed) — a screen-space key makes the canopy crawl.
bool veg_leaf_fallen(vec2 key, float coverage, float decid) {
	float loss = veg_leaf_loss(coverage, decid);
	return loss > 0.001 && veg_phenology_hash(key) < loss;
}

// Per-tree hue pick along the yellow -> orange -> red ramp, so neighbouring
// trees turn to different colours.
vec3 veg_autumn_color(float var01, vec3 warm, vec3 orange, vec3 hot) {
	return var01 < 0.5
		? mix(warm, orange, var01 * 2.0)
		: mix(orange, hot, (var01 - 0.5) * 2.0);
}

vec3 veg_apply_autumn(vec3 albedo, float amount, float var01,
		vec3 warm, vec3 orange, vec3 hot) {
	float amt = clamp(amount, 0.0, 1.0);
	if (amt <= 0.001) {
		return albedo;
	}
	vec3 col = veg_autumn_color(var01, warm, orange, hot);
	float luma = dot(albedo, vec3(0.299, 0.587, 0.114));
	// Nearly full blend: foliage must clearly CHANGE COLOUR before leaf loss
	// thins it out, rather than merely fading away.
	return mix(albedo, col * (0.72 + luma * 0.5), amt * 0.92);
}

// Dormancy: gentle desaturation + darkening of whatever foliage remains. Driven
// by the foliage mask alone, NOT by deciduousness — evergreens keep their
// needles and those needles are exactly what greys off in winter light.
vec3 veg_apply_winter(vec3 albedo, float amount) {
	float g = dot(albedo, vec3(0.299, 0.587, 0.114));
	return mix(albedo, mix(albedo, vec3(g), 0.30) * 0.85, clamp(amount, 0.0, 1.0) * 0.6);
}

// Spring: fresh light-green flush on deciduous leaf-out.
vec3 veg_apply_bud(vec3 albedo, float amount, vec3 bud_col) {
	return mix(albedo, albedo * 0.5 + bud_col * 0.5, clamp(amount, 0.0, 1.0) * 0.6);
}
