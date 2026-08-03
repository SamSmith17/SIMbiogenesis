class_name VegTreeArchetypes
extends RefCounted

## Vegetation Overhaul v2: the shape-archetype table + macro-slider mapping.
##
## The v3 style model exposes REAL-WORLD primary knobs (height_m,
## crown_width_m, trunk_diameter_cm, crown_base_pct) plus one archetype pick
## and four 0..1 character macros (branchiness / crookedness / droop /
## foliage_density). The space-colonization builder keeps all of its internal
## tuning knobs — they just stop being user-facing style keys. This file is
## the ONE place that maps (archetype, macros) → internal builder params, so
## a shape change is a data edit here, not a slider-plumbing change.
##
## Internal param names are prefixed `sc_` and travel inside the SPEC dict the
## builders consume (never the settings/style dict — they must not be
## persisted or hashed into style state).

const IDS: Array[String] = [
	"round", "spreading", "columnar", "vase", "weeping", "conical",
]

const LABELS := {
	"round": "Round",
	"spreading": "Spreading",
	"columnar": "Columnar",
	"vase": "Vase",
	"weeping": "Weeping",
	"conical": "Conical",
}

## Per-archetype internal shape params.
##  tilt_low/high  — splay (deg from vertical) of lowest/highest primaries
##  lateral        — attractor bias toward the lower crown (spreading skirt)
##  crown_aspect   — crown height / crown width (envelope proportions)
##  env_bottom     — envelope base fullness 0..1 (radius at crown base)
##  env_mid        — height fraction where the envelope is widest
##  pull_bias      — added attractor pull (crooked chase vs straight habit)
##  droop_bias     — baseline gravitropism (weeping floor)
##  taper          — trunk top radius fraction
##  primaries      — baseline primary limb count (branchiness modulates)
const ARCHETYPES := {
	"round": {
		"tilt_low": 68.0, "tilt_high": 24.0, "lateral": 0.5,
		"crown_aspect": 0.85, "env_bottom": 0.55, "env_mid": 0.45,
		"pull_bias": 0.0, "droop_bias": 0.08, "taper": 0.55, "primaries": 6,
	},
	"spreading": {
		"tilt_low": 84.0, "tilt_high": 38.0, "lateral": 0.68,
		"crown_aspect": 0.55, "env_bottom": 0.78, "env_mid": 0.35,
		"pull_bias": 0.08, "droop_bias": 0.10, "taper": 0.62, "primaries": 5,
	},
	"columnar": {
		"tilt_low": 38.0, "tilt_high": 12.0, "lateral": 0.35,
		"crown_aspect": 1.9, "env_bottom": 0.42, "env_mid": 0.5,
		"pull_bias": -0.08, "droop_bias": 0.02, "taper": 0.45, "primaries": 7,
	},
	"vase": {
		"tilt_low": 30.0, "tilt_high": 55.0, "lateral": 0.3,
		"crown_aspect": 0.95, "env_bottom": 0.25, "env_mid": 0.78,
		"pull_bias": 0.0, "droop_bias": -0.06, "taper": 0.5, "primaries": 6,
	},
	"weeping": {
		"tilt_low": 55.0, "tilt_high": 30.0, "lateral": 0.55,
		"crown_aspect": 0.95, "env_bottom": 0.62, "env_mid": 0.55,
		"pull_bias": 0.05, "droop_bias": 0.55, "taper": 0.5, "primaries": 6,
	},
	"conical": {
		"tilt_low": 78.0, "tilt_high": 20.0, "lateral": 0.45,
		"crown_aspect": 1.5, "env_bottom": 0.95, "env_mid": 0.12,
		"pull_bias": -0.05, "droop_bias": 0.12, "taper": 0.35, "primaries": 7,
	},
}


static func is_valid(id: String) -> bool:
	return ARCHETYPES.has(id)


static func label_for(id: String) -> String:
	return str(LABELS.get(id, id.capitalize()))


## The internal SC parameter set for one tree, from the archetype + the four
## 0..1 character macros + the deterministic variant seed. Consumed by
## VegetationCardFactory._deciduous_spec / _build_branch_skeleton.
static func builder_params(archetype: String, branchiness: float,
		crookedness: float, droop: float, variant_seed: int) -> Dictionary:
	var a: Dictionary = ARCHETYPES.get(archetype, ARCHETYPES["round"])
	var b := clampf(branchiness, 0.0, 1.0)
	var c := clampf(crookedness, 0.0, 1.0)
	var d := clampf(droop, 0.0, 1.0)
	return {
		"sc_primaries": clampi(int(round(float(a["primaries"]) * lerpf(0.6, 1.7, b))), 3, 12),
		# Node budget scales cost with branchiness; the tri-budget selftest is
		# the guard on the top end.
		"sc_node_budget": int(lerpf(150.0, 420.0, b)),
		"sc_lateral": clampf(float(a["lateral"]) * lerpf(0.7, 1.4, b), 0.0, 1.0),
		"sc_tilt_low": float(a["tilt_low"]),
		"sc_tilt_high": float(a["tilt_high"]),
		# Attractor pull: crooked trees chase open space hard (wandering oaks),
		# straight habits keep their heading (poplars).
		"sc_pull": clampf(0.38 + 0.5 * c + float(a["pull_bias"]), 0.25, 0.92),
		"sc_gnarl": lerpf(0.02, 0.85, c),
		"sc_droop": clampf(float(a["droop_bias"]) + d * 0.9, -0.2, 1.2),
		"sc_crown_aspect": float(a["crown_aspect"]),
		"sc_env_bottom": float(a["env_bottom"]),
		"sc_env_mid": float(a["env_mid"]),
		"sc_taper": float(a["taper"]),
		"sc_seed": clampi(variant_seed, 0, 9),
	}


## Foliage macro: one slider drives the coupled leaf/clump knobs so "denser
## foliage" always means what it says (the individual knobs stay reachable
## under Advanced and win when explicitly set).
static func foliage_params(density: float) -> Dictionary:
	var d := clampf(density, 0.0, 1.0)
	return {
		"leaf_density": lerpf(8.0, 27.0, d),
		# Delta on the quality tier's shell count, so LOW/HIGH tiers keep their
		# cost identity while the slider still breathes within it.
		"shell_delta": int(round(lerpf(-1.0, 2.0, d))),
		"cluster_size": lerpf(0.8, 1.3, d),
		"leaf_gap": lerpf(0.22, 0.03, d),
	}
