class_name PpSheetPressSource
extends RefCounted
## Precious Plastic sheet press physics (batch flake → 1 m² recycled sheet).
##
## Specs (workshop datasheet):
##   Energy: 3–5 kWh per hour of active production (peak on warm-up, then
##           thermostat cycling of heaters).
##   Throughput: ~6–14 kg/h (effective = sheet_mass / cycle_time).
##   Material: 1 m² × thickness × ρ_PP — pinned to 8 mm → 7.2 kg, 15 mm → 13.5 kg
##             (ρ = 900 kg/m³ ⇒ kg = 0.9 × thickness_mm).
##   Thin (5–8 mm):  50–60 min total (melt 30–35 + cool 20–25).
##   Thick (12–20 mm): 90–120 min (melt 60–70 + cool 30–50 under pressure).
##
## Progress is scrub-safe via absolute hours (same pattern as CartesianMachineSource).

const AREA_M2 := 1.0
const PP_DENSITY_KG_M3 := 900.0  # pins 8 mm → 7.2 kg, 15 mm → 13.5 kg
const MIN_THICKNESS_MM := 5.0
const MAX_THICKNESS_MM := 20.0
const DEFAULT_THICKNESS_MM := 8.0
const PEAK_WATTS := 5000.0
const AVG_KWH_PER_H_MIN := 3.0
const AVG_KWH_PER_H_MAX := 5.0
const WARMUP_FRAC_OF_MELT := 0.12  # first ~12% of melt at peak heater power
const HEATER_CYCLE_PERIOD_H := 2.0 / 60.0  # ~2 min thermostat period
const MIN_JOB_HOURS := 0.01


static func clamp_thickness_mm(mm: float) -> float:
	return clampf(mm, MIN_THICKNESS_MM, MAX_THICKNESS_MM)


## Mass of one 1 m² sheet at the given thickness (kg).
static func sheet_mass_kg(thickness_mm: float) -> float:
	var t_m := clamp_thickness_mm(thickness_mm) * 0.001
	return AREA_M2 * t_m * PP_DENSITY_KG_M3


## {melt_hr, cool_hr, total_hr} interpolated from thin/thick workshop bands.
static func cycle_times_hr(thickness_mm: float) -> Dictionary:
	var t := clamp_thickness_mm(thickness_mm)
	# Anchor points (minutes → hours): 5 / 8 / 12 / 20 mm.
	var melt_min: float
	var cool_min: float
	if t <= 8.0:
		var u := inverse_lerp(5.0, 8.0, t)
		melt_min = lerpf(30.0, 35.0, u)
		cool_min = lerpf(20.0, 25.0, u)
	elif t <= 12.0:
		var u2 := inverse_lerp(8.0, 12.0, t)
		melt_min = lerpf(35.0, 60.0, u2)
		cool_min = lerpf(25.0, 30.0, u2)
	else:
		var u3 := inverse_lerp(12.0, 20.0, t)
		melt_min = lerpf(60.0, 70.0, u3)
		cool_min = lerpf(30.0, 50.0, u3)
	var melt_hr := melt_min / 60.0
	var cool_hr := cool_min / 60.0
	return {
		"melt_hr": melt_hr,
		"cool_hr": cool_hr,
		"total_hr": maxf(melt_hr + cool_hr, MIN_JOB_HOURS),
	}


## Effective flake throughput for a full cycle (kg/h).
static func throughput_kg_h(thickness_mm: float) -> float:
	var mass := sheet_mass_kg(thickness_mm)
	var total := float(cycle_times_hr(thickness_mm).get("total_hr", MIN_JOB_HOURS))
	return mass / maxf(total, MIN_JOB_HOURS)


## Average kWh/h during active production — slightly higher for thicker sheets
## (longer cool-under-pressure, more heater cycling).
static func avg_kwh_per_h(thickness_mm: float) -> float:
	var u := inverse_lerp(MIN_THICKNESS_MM, MAX_THICKNESS_MM, clamp_thickness_mm(thickness_mm))
	return lerpf(AVG_KWH_PER_H_MIN, AVG_KWH_PER_H_MAX, u)


static func derive_job(specs: Dictionary) -> Dictionary:
	var thick := clamp_thickness_mm(float(specs.get("sheet_thickness_mm", DEFAULT_THICKNESS_MM)))
	var times := cycle_times_hr(thick)
	var mass := sheet_mass_kg(thick)
	var avg_kwh := avg_kwh_per_h(thick)
	var total_hr := float(times.get("total_hr", MIN_JOB_HOURS))
	return {
		"thickness_mm": thick,
		"material_kg": mass,
		"melt_hr": float(times.get("melt_hr", 0.0)),
		"cool_hr": float(times.get("cool_hr", 0.0)),
		"duration_hr": total_hr,
		"avg_kwh_per_h": avg_kwh,
		"energy_kwh": avg_kwh * total_hr,
		"throughput_kg_h": mass / maxf(total_hr, MIN_JOB_HOURS),
		"part_id": "pp_sheet_%.0fmm" % thick,
		"part_label": "Recycled Plastic Sheet (1 m² × %.0f mm)" % thick,
	}


## Scrub-safe 0..1 progress over the whole cycle.
static func progress_at(specs: Dictionary, abs_hours: float) -> float:
	if not bool(specs.get("job_active", false)):
		return 1.0 if bool(specs.get("job_completed", false)) else 0.0
	var start := float(specs.get("job_start_abs_hours", abs_hours))
	var dur := maxf(float(specs.get("job_duration_hr", 0.0)), MIN_JOB_HOURS)
	return clampf((abs_hours - start) / dur, 0.0, 1.0)


## Phase within an active job: "idle" | "melt" | "cool" | "done".
static func phase_at(specs: Dictionary, abs_hours: float) -> String:
	if not bool(specs.get("job_active", false)):
		return "done" if bool(specs.get("job_completed", false)) else "idle"
	var start := float(specs.get("job_start_abs_hours", abs_hours))
	var melt_hr := maxf(float(specs.get("job_melt_hr", 0.0)), 0.0)
	var cool_hr := maxf(float(specs.get("job_cool_hr", 0.0)), 0.0)
	var elapsed := abs_hours - start
	if elapsed < 0.0:
		return "melt"
	if elapsed < melt_hr:
		return "melt"
	if elapsed < melt_hr + cool_hr:
		return "cool"
	return "done"


## Compression 0..1 for Z-axis animation: closes over melt, holds through cool.
static func compression_at(specs: Dictionary, abs_hours: float) -> float:
	var phase := phase_at(specs, abs_hours)
	if phase == "idle":
		return 0.0
	if phase == "cool" or phase == "done":
		return 1.0
	# melt: ease closed over the melt window
	var start := float(specs.get("job_start_abs_hours", abs_hours))
	var melt_hr := maxf(float(specs.get("job_melt_hr", MIN_JOB_HOURS)), MIN_JOB_HOURS)
	var u := clampf((abs_hours - start) / melt_hr, 0.0, 1.0)
	# Smoothstep for a hydraulic feel
	return u * u * (3.0 - 2.0 * u)


## Instantaneous heater/hydraulic draw (W) while a job is active.
## Peak during warm-up, then on/off cycling around the datasheet average.
static func power_watts_at(specs: Dictionary, abs_hours: float) -> float:
	if not bool(specs.get("job_active", false)):
		return 0.0
	var phase := phase_at(specs, abs_hours)
	if phase == "done" or phase == "idle":
		return 0.0
	var peak := maxf(float(specs.get("peak_watts", PEAK_WATTS)), 500.0)
	var avg_kwh := float(specs.get("job_avg_kwh_per_h", avg_kwh_per_h(
		float(specs.get("sheet_thickness_mm", DEFAULT_THICKNESS_MM)))))
	var avg_w := avg_kwh * 1000.0
	var start := float(specs.get("job_start_abs_hours", abs_hours))
	var melt_hr := maxf(float(specs.get("job_melt_hr", MIN_JOB_HOURS)), MIN_JOB_HOURS)
	var elapsed := abs_hours - start
	var warmup_hr := melt_hr * WARMUP_FRAC_OF_MELT
	if phase == "melt" and elapsed <= warmup_hr:
		return peak
	# Cool phase still needs some heater cycling (warping control) but lower duty.
	var target_avg := avg_w if phase == "melt" else avg_w * 0.45
	var duty := clampf(target_avg / peak, 0.05, 0.95)
	var period := maxf(float(specs.get("heater_cycle_period_h", HEATER_CYCLE_PERIOD_H)), 1.0 / 3600.0)
	var cycle_u := fposmod(elapsed, period) / period
	return peak if cycle_u < duty else 0.0


## Flake draw rate (kg/h) during melt only; 0 while cooling / idle.
static func material_rate_per_hr(specs: Dictionary, abs_hours: float) -> float:
	if phase_at(specs, abs_hours) != "melt":
		return 0.0
	var qty := float(specs.get("job_material_qty", 0.0))
	var melt_hr := maxf(float(specs.get("job_melt_hr", 0.0)), MIN_JOB_HOURS)
	if qty <= 0.0:
		return 0.0
	return qty / melt_hr
