class_name SiphonHydraulics
extends RefCounted

## Siphon micro-hydro: primes when pond level reaches siphon_start_m, flows while
## primed with head to the outlet invert, breaks when level drops below
## siphon_break_m. Electrical = η_h·η_g·PE (optional nameplate via max_power_w).
## Rotor ω tracks hydraulic PE. Pure static — selftested.

const WATER_DENSITY := CulvertHydraulics.WATER_DENSITY
const G := CulvertHydraulics.G
## Tip-speed style: rad/s at the PE reference (≈ 1200 rpm).
const OMEGA_AT_RATED := 125.6
## Hydraulic PE (W) that maps to OMEGA_AT_RATED — rotor tracks available head×flow,
## not the electrical nameplate clamp.
const PE_AT_RATED_W := 5000.0


## Simulate one siphon step using start/break levels (preferred) or legacy
## crown/invert. Returns q, head, pe_w, power_w, primed, regime, rpm, omega.
## `max_power_w` ≤ 0 means uncapped electrical (η·PE); >0 is an optional nameplate.
static func simulate(
		pond_level_m: float,
		intake_invert_m: float,
		intake_crown_m: float,
		outlet_invert_m: float,
		intake_diameter_m: float = 0.203,
		outlet_diameter_m: float = 0.203,
		barrel_length_m: float = 20.0,
		manning_n: float = CulvertHydraulics.DEFAULT_MANNING_N,
		primed_prev: bool = false,
		max_power_w: float = 0.0,
		hydraulic_efficiency: float = 0.6,
		generator_efficiency: float = 0.7,
		siphon_start_m: float = NAN,
		siphon_break_m: float = NAN) -> Dictionary:
	var start_m := siphon_start_m if not is_nan(siphon_start_m) else intake_crown_m
	var break_m := siphon_break_m if not is_nan(siphon_break_m) else intake_invert_m
	var invert := break_m
	var crown := start_m
	if is_nan(crown) and not is_nan(invert):
		crown = invert + maxf(intake_diameter_m, 0.05)
	if is_nan(invert) and not is_nan(crown):
		invert = crown - maxf(intake_diameter_m, 0.05)
	var out := {
		"q_lps": 0.0,
		"q_m3s": 0.0,
		"q_lph": 0.0,
		"head_m": 0.0,
		"pe_w": 0.0,
		"power_w": 0.0,
		"power_kw": 0.0,
		"primed": false,
		"regime": "dry",
		"omega": 0.0,
		"rpm": 0.0,
		"siphon_start_m": crown,
		"siphon_break_m": invert,
	}
	if is_nan(invert) or is_nan(crown) or is_nan(outlet_invert_m):
		out["regime"] = "unset"
		return out
	if crown < invert:
		var tmp := crown
		crown = invert
		invert = tmp
	var primed := primed_prev
	if pond_level_m >= crown:
		primed = true
	if pond_level_m < invert:
		primed = false
	out["primed"] = primed
	out["siphon_start_m"] = crown
	out["siphon_break_m"] = invert
	if not primed:
		out["regime"] = "broken" if primed_prev else "dry"
		return out
	var head := pond_level_m - outlet_invert_m
	out["head_m"] = maxf(head, 0.0)
	if head <= 1e-4:
		out["regime"] = "no_head"
		return out
	var d_orifice := minf(maxf(intake_diameter_m, 0.05), maxf(outlet_diameter_m, 0.05))
	var cul := CulvertHydraulics.stage_discharge(
		pond_level_m, invert, outlet_invert_m,
		d_orifice, maxf(barrel_length_m, 0.5), manning_n)
	var q_m3s := float(cul.get("q_m3s", 0.0))
	out["q_m3s"] = q_m3s
	out["q_lps"] = q_m3s * 1000.0
	out["q_lph"] = q_m3s * 1000.0 * 3600.0
	out["regime"] = "siphon_%s" % str(cul.get("regime", "flow"))
	var pe_w := WATER_DENSITY * G * q_m3s * maxf(head, 0.0)
	out["pe_w"] = pe_w
	var eta := clampf(hydraulic_efficiency, 0.05, 1.0) \
			* clampf(generator_efficiency, 0.05, 1.0)
	var power_w := pe_w * eta
	if max_power_w > 1e-6:
		power_w = minf(power_w, max_power_w)
	out["power_w"] = power_w
	out["power_kw"] = power_w / 1000.0
	# Rotor ∝ available hydraulic PE (and thus Q·H), not the nameplate clamp.
	var omega := omega_from_pe_w(pe_w)
	out["omega"] = omega
	out["rpm"] = omega * 60.0 / TAU
	return out


## Convenience: simulate from processor specs + pond level.
## Resolves start/break from module elevation + offsets when present.
static func simulate_from_specs(pond_level_m: float, specs: Dictionary) -> Dictionary:
	var d_in := maxf(float(specs.get("intake_diameter_mm", 203.0)) / 1000.0, 0.05)
	var d_out := maxf(float(specs.get("outlet_diameter_mm", 203.0)) / 1000.0, 0.05)
	var levels := resolve_siphon_levels(specs)
	var start_m := float(levels.get("siphon_start_m", NAN))
	var break_m := float(levels.get("siphon_break_m", NAN))
	var crown := float(specs.get("intake_crown_m", NAN))
	var inv := float(specs.get("intake_invert_m", NAN))
	if is_nan(start_m):
		start_m = crown
	if is_nan(break_m):
		break_m = inv
	var out_inv := float(specs.get("outlet_invert_m", NAN))
	return simulate(
		pond_level_m, inv, crown, out_inv, d_in, d_out,
		float(specs.get("barrel_length_m", 20.0)),
		float(specs.get("manning_n", CulvertHydraulics.DEFAULT_MANNING_N)),
		bool(specs.get("siphon_primed", false)),
		float(specs.get("max_power_w", 0.0)),
		float(specs.get("hydraulic_efficiency", 0.6)),
		float(specs.get("generator_efficiency", 0.7)),
		start_m, break_m)


static func crown_from_invert(invert_m: float, diameter_m: float) -> float:
	return invert_m + maxf(diameter_m, 0.05)


## Default break offset below the turbine module (metres).
const DEFAULT_BREAK_OFFSET_M := -0.4


## Resolve module / start / break from 3D module elev + relative offsets.
## `elevation_m` overrides specs.module_elev_m when finite (live prop Y).
## Migrates legacy absolute start/break into offsets when offsets are missing.
## Returns {module_elev_m, siphon_start_m, siphon_break_m,
##          siphon_start_offset_m, siphon_break_offset_m}.
static func resolve_siphon_levels(specs: Dictionary,
		elevation_m: float = NAN) -> Dictionary:
	var d_in := maxf(float(specs.get("intake_diameter_mm", 203.0)) / 1000.0, 0.05)
	# Stored module = datum the absolute start/break were authored against.
	var module_stored := float(specs.get("module_elev_m", NAN))
	if is_nan(module_stored):
		module_stored = float(specs.get("elevation_m", NAN))
	# Live module (3D prop Y) overrides for evaluation; migration still uses stored.
	var module := elevation_m if not is_nan(elevation_m) else module_stored
	var break_off := float(specs.get("siphon_break_offset_m", NAN))
	var start_off := float(specs.get("siphon_start_offset_m", NAN))
	var abs_break := float(specs.get("siphon_break_m", NAN))
	var abs_start := float(specs.get("siphon_start_m", NAN))
	# Migrate absolutes → offsets against the AUTHORING datum, not a new elev.
	var migrate_datum := module_stored if not is_nan(module_stored) else module
	if not is_nan(migrate_datum):
		if is_nan(break_off) and not is_nan(abs_break):
			break_off = abs_break - migrate_datum
		if is_nan(start_off) and not is_nan(abs_start):
			start_off = abs_start - migrate_datum
	if is_nan(break_off):
		break_off = DEFAULT_BREAK_OFFSET_M
	if is_nan(start_off):
		# Crown above break (pipe ID), expressed relative to module.
		start_off = break_off + d_in
	if is_nan(module):
		# No module datum — fall back to stored absolutes / legacy crowns.
		var fb_break := abs_break if not is_nan(abs_break) \
				else float(specs.get("intake_invert_m", NAN))
		var fb_start := abs_start if not is_nan(abs_start) \
				else float(specs.get("intake_crown_m", NAN))
		if is_nan(fb_break) and not is_nan(fb_start):
			fb_break = fb_start - d_in
		if is_nan(fb_start) and not is_nan(fb_break):
			fb_start = crown_from_invert(fb_break, d_in)
		return {
			"module_elev_m": NAN,
			"siphon_start_m": fb_start,
			"siphon_break_m": fb_break,
			"siphon_start_offset_m": start_off,
			"siphon_break_offset_m": break_off,
		}
	if start_off <= break_off:
		start_off = break_off + d_in
	return {
		"module_elev_m": module,
		"siphon_start_m": module + start_off,
		"siphon_break_m": module + break_off,
		"siphon_start_offset_m": start_off,
		"siphon_break_offset_m": break_off,
	}


## Stamp resolved absolutes + offsets onto a specs dict (mutates + returns).
static func apply_resolved_levels(specs: Dictionary,
		elevation_m: float = NAN) -> Dictionary:
	var levels := resolve_siphon_levels(specs, elevation_m)
	var module := float(levels.get("module_elev_m", NAN))
	if not is_nan(module):
		specs["module_elev_m"] = module
	specs["siphon_start_offset_m"] = float(levels.get("siphon_start_offset_m",
			DEFAULT_BREAK_OFFSET_M + 0.2))
	specs["siphon_break_offset_m"] = float(levels.get("siphon_break_offset_m",
			DEFAULT_BREAK_OFFSET_M))
	var start_m := float(levels.get("siphon_start_m", NAN))
	var break_m := float(levels.get("siphon_break_m", NAN))
	if not is_nan(start_m):
		specs["siphon_start_m"] = start_m
		specs["intake_crown_m"] = start_m
	if not is_nan(break_m):
		specs["siphon_break_m"] = break_m
		specs["intake_invert_m"] = break_m
	return specs


## Target rotor ω (rad/s) from hydraulic PE — primary spin driver.
static func omega_from_pe_w(pe_w: float, pe_ref_w: float = PE_AT_RATED_W) -> float:
	if pe_w <= 0.0 or pe_ref_w <= 1e-6:
		return 0.0
	return OMEGA_AT_RATED * clampf(pe_w / pe_ref_w, 0.0, 1.25)


## Legacy helper: ω from electrical watts / nameplate (kept for call sites).
static func omega_from_power_w(power_w: float, max_power_w: float = 0.0) -> float:
	if power_w <= 0.0:
		return 0.0
	if max_power_w > 1e-6:
		return OMEGA_AT_RATED * clampf(power_w / max_power_w, 0.0, 1.0)
	# No nameplate — map electrical through η≈0.42 back toward PE space.
	return omega_from_pe_w(power_w / 0.42)
