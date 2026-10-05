// Per-instance plant growth — a LINE-FOR-LINE MIRROR of
// VegGrowthModel.state() (vegetation/veg_growth_model.gd). Edit both; the
// growth selftest parses the constants below out of this file and compares
// them with the model's.
//
// A plant is four numbers in INSTANCE_CUSTOM, written once when its batch is
// built (VegetationGrowth.instance_custom):
//     x  birth growth-year − 2000
//     y  maturity age (years to full size)      0 = growth OFF (identity)
//     z  lifespan (years, already jittered)     0 = grow and hold
//     w  seed 0..1
// and the only thing that changes as time passes is ONE uniform, growth_year.
// No transforms are rewritten and nothing is rebuilt as the years go by.
//
// IDENTITY: a plain MeshInstance3D (the impostor baker, the Tune-look preview,
// the tree portraits) reads INSTANCE_CUSTOM = 0, so y == 0 MUST mean full size.

// Growth-year now, minus 2000 (VegetationEnvironmentSync pushes it).
uniform float growth_year = 0.0;
// > 0.5 = growth switched off in the settings: everything draws mature.
uniform float growth_freeze = 0.0;
// Model-space Y of the plant's foot: scaling pivots here (0 for trees).
uniform float growth_pivot_y = 0.0;

const float VG_CR_K = 3.0;
const float VG_CR_P = 1.6;
const float VG_SEED_HEIGHT = 0.03;
const float VG_CROWN_EXP = 1.35;
const float VG_GIRTH_EXP = 1.6;
const float VG_OLD_GIRTH = 1.2;
const float VG_DECLINE_FRAC = 0.04;
const float VG_LEAF_LOSS_FRAC = 0.6;
const float VG_COLLAPSE_FRAC = 0.15;
const float VG_GAP_MIN_Y = 2.0;
const float VG_GAP_SPAN_Y = 2.0;
const float VG_REGEN_HEAD_START = 0.15;
const float VG_MIN_LIFE_RATIO = 1.25;
// Cosmetic only (the CPU model reports sizes WITHOUT these): each regrown
// generation is a slightly different individual in a slightly different spot.
const float VG_GEN_SIZE_JITTER = 0.16;
const float VG_GEN_OFFSET_M = 1.0;

float vg_height_curve(float x) {
	if (x >= 1.0) {
		return 1.0;
	}
	float cr = pow(1.0 - exp(-VG_CR_K * max(x, 0.0)), VG_CR_P)
		/ pow(1.0 - exp(-VG_CR_K), VG_CR_P);
	return mix(VG_SEED_HEIGHT, 1.0, cr);
}

// Returns (height, crown, girth, leaf); `gen` = which generation stands here.
// Later generations rise out of the gap as a released sapling (see the model).
vec4 veg_growth_state(vec4 g, out float gen) {
	gen = 0.0;
	float maturity = g.y;
	if (maturity <= 0.0 || growth_freeze > 0.5) {
		return vec4(1.0);
	}
	float elapsed = max(growth_year - g.x, 0.0);
	float age = elapsed;
	float life = 0.0;
	float emerge = 1.0;
	if (g.z > 0.0) {
		life = max(g.z, maturity * VG_MIN_LIFE_RATIO);
		if (elapsed >= life) {
			float a0 = VG_REGEN_HEAD_START * maturity;
			float gap = VG_GAP_MIN_Y + VG_GAP_SPAN_Y * clamp(g.w, 0.0, 1.0);
			float cycle = gap + life - a0;
			float e2 = elapsed - life;
			float k = floor(e2 / cycle);
			float r = e2 - k * cycle;
			gen = 1.0 + k;
			if (r < gap) {
				age = a0;
				emerge = smoothstep(0.0, 1.0, r / gap);
			} else {
				age = a0 + (r - gap);
			}
		}
	}
	float h = vg_height_curve(age / maturity);
	float crown = pow(h, VG_CROWN_EXP) * emerge;
	float girth = pow(h, VG_GIRTH_EXP) * emerge;
	h *= emerge;
	float leaf = 1.0;
	if (life > 0.0) {
		float d0 = life * (1.0 - VG_DECLINE_FRAC);
		if (age > maturity) {
			girth = mix(1.0, VG_OLD_GIRTH, smoothstep(maturity, d0, age));
		}
		if (age > d0) {
			float u = min((age - d0) / (life - d0), 1.0);
			leaf = 1.0 - smoothstep(0.0, VG_LEAF_LOSS_FRAC, u);
			float stand = 1.0 - smoothstep(1.0 - VG_COLLAPSE_FRAC, 1.0, u);
			h *= stand;
			crown *= stand;
			girth *= stand;
		}
	}
	return vec4(h, crown, girth, leaf);
}

float vg_hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Per-generation individuality: (size multiplier, x offset, z offset).
// Generation 0 — the plant the player actually placed — is exact.
vec3 veg_growth_generation(float gen, float seed) {
	if (gen < 0.5) {
		return vec3(1.0, 0.0, 0.0);
	}
	vec2 k = vec2(gen, seed * 91.7);
	return vec3(
		1.0 + (vg_hash(k) - 0.5) * VG_GEN_SIZE_JITTER,
		(vg_hash(k + 17.3) - 0.5) * 2.0 * VG_GEN_OFFSET_M,
		(vg_hash(k + 41.9) - 0.5) * 2.0 * VG_GEN_OFFSET_M);
}

// Scale a MODEL-space vertex about the foot. `radial` is the factor for the
// horizontal extent — crown for foliage, girth for the stem.
vec3 veg_growth_apply(vec3 v, float height, float radial, vec3 gen_var) {
	v.y = growth_pivot_y + (v.y - growth_pivot_y) * height * gen_var.x;
	v.xz = v.xz * (radial * gen_var.x) + gen_var.yz * step(0.0001, height);
	return v;
}

// True when this leaf/needle clump has gone from a declining tree. `key` must
// be stable in the tree's own frame, like the seasonal leaf-fall key.
bool veg_growth_leaf_gone(vec2 key, float leaf) {
	return leaf < 0.999 && vg_hash(key + 7.7) >= leaf;
}
