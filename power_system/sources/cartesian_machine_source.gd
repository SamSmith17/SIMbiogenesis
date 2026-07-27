class_name CartesianMachineSource
extends RefCounted

## Physics/accounting adapter for Cartesian CNC machines (FDM/flake 3D printer,
## CNC router/mill, laser, …) driven from an uploaded real job (G-code parsed by
## Toolpath, or STL by StlLoader). Static, like csp_trough_source.gd — the 3D
## animation (CncMachineRuntime) and the graph tick (SystemGraphView._tick_graph_
## tools) both read from these pure functions so simulated time, energy, and
## material stay consistent.
##
## Job time comes from the file's own feed/volume estimate, divided by a machine
## speed_factor. Material for an additive printer is derived from extruded volume
## (G-code E advance through a filament cross-section, or STL solid volume) times
## the feedstock density. A subtractive router consumes no feedstock by default
## (stock is removed, not fed) — it just spends energy + time. Energy = rated
## running watts x runtime.

## FDM filament cross-section default (mm) when a G-code file gives extrusion in
## E-length rather than volume.
const DEFAULT_FILAMENT_DIAMETER_MM := 1.75
## Recycled-flake bulk density (g/cm3) — HDPE/PP class default.
const DEFAULT_FLAKE_DENSITY_G_CM3 := 0.95
const MIN_JOB_HOURS := 0.0005


## Derives the schedulable job parameters from a parsed file + the machine specs.
## `parse` is the dict returned by Toolpath.parse_* / StlLoader.parse_*.
static func derive_job(parse: Dictionary, specs: Dictionary) -> Dictionary:
	var role := str(specs.get("machine_role", "generic"))
	var speed_factor := maxf(float(specs.get("speed_factor", 1.0)), 0.05)
	var est_hr := maxf(float(parse.get("est_time_hr", 0.0)), 0.0)
	var duration_hr := maxf(est_hr / speed_factor, MIN_JOB_HOURS)

	var material_kind := ""
	var inputs: Array = specs.get("inputs", []) as Array
	if not inputs.is_empty() and inputs[0] is Dictionary:
		material_kind = str((inputs[0] as Dictionary).get("kind", ""))

	var material_qty := 0.0
	if role == "fdm_printer":
		var density := maxf(float(specs.get("flake_density_g_cm3", DEFAULT_FLAKE_DENSITY_G_CM3)), 0.05)
		var vol_mm3 := 0.0
		var extrusion_mm := float(parse.get("extrusion_mm", 0.0))
		if extrusion_mm > 0.0:
			var d := maxf(float(specs.get("filament_diameter_mm", DEFAULT_FILAMENT_DIAMETER_MM)), 0.1)
			var area := PI * (d * 0.5) * (d * 0.5)
			vol_mm3 = extrusion_mm * area
		else:
			vol_mm3 = float(parse.get("volume_mm3", 0.0))
		# g = cm3 * (g/cm3); mm3 -> cm3 is /1000; g -> kg is /1000.
		material_qty = (vol_mm3 / 1000.0) * density / 1000.0

	var watts := maxf(float(specs.get("watts", 0.0)), 0.0)
	var energy_kwh := watts / 1000.0 * duration_hr

	var bmin: Vector3 = parse.get("bounds_min", Vector3.ZERO)
	var bmax: Vector3 = parse.get("bounds_max", Vector3.ZERO)

	return {
		"duration_hr": duration_hr,
		"material_kind": material_kind,
		"material_qty": material_qty,
		"energy_kwh": energy_kwh,
		"bounds_size_mm": bmax - bmin,
		"point_count": int(parse.get("point_count", 0)),
		"kind": str(parse.get("kind", "")),
	}


## Material draw rate (qty/hour) while running — feeds specs.inputs[0].rate so
## ResourceFlowEngine debits the wired feedstock tank. 0 for subtractive/no-feed.
static func material_rate_per_hr(specs: Dictionary) -> float:
	var qty := float(specs.get("job_material_qty", 0.0))
	var dur := float(specs.get("job_duration_hr", 0.0))
	if qty <= 0.0 or dur <= 0.0:
		return 0.0
	return qty / dur


## Scrub-safe job progress (0..1): a pure function of the absolute-hours clock,
## so it advances/rewinds correctly at any time-scale or timeline scrub — exactly
## like the sun-driven trackers. Returns 0 when no job is scheduled.
static func progress_at(specs: Dictionary, abs_hours: float) -> float:
	if not bool(specs.get("job_active", false)):
		return 1.0 if bool(specs.get("job_completed", false)) else 0.0
	var start := float(specs.get("job_start_abs_hours", abs_hours))
	var dur := maxf(float(specs.get("job_duration_hr", 0.0)), MIN_JOB_HOURS)
	return clampf((abs_hours - start) / dur, 0.0, 1.0)
