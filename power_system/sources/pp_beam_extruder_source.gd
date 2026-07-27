class_name PpBeamExtruderSource
extends RefCounted
## Precious Plastic beam extruder physics (continuous flake → cut beams).
##
## Datasheet-style rates (PP workshop):
##   Plastic flake in: 5 kg/h
##   AC draw: 1200 W
##   Linear density: 1.17 kg per linear metre (1×2″ / 1×3″ recycled beam stock)
##   Growth rate: 5 / 1.17 ≈ 4.274 m/h when fully fed + powered
##
## While the graph processor is RUNNING, sim-hours advance the extruded length.
## Each time length reaches `cut_length_m`, one beam is cut (inventory credit)
## and the remainder carries into the next stick.

const DEFAULT_FLAKE_KG_H := 5.0
const DEFAULT_KG_PER_M := 1.17
const DEFAULT_CUT_LENGTH_M := 2.0
const DEFAULT_WATTS := 1200.0


## Linear metres extruded per hour at full flake throughput.
static func meters_per_hour(specs: Dictionary) -> float:
	var kg_h := maxf(float(specs.get("flake_kg_h", DEFAULT_FLAKE_KG_H)), 0.001)
	# Prefer live input rate when the tick has stamped it.
	var inputs: Array = specs.get("inputs", []) as Array
	if not inputs.is_empty() and inputs[0] is Dictionary:
		var r := float((inputs[0] as Dictionary).get("rate", 0.0))
		if r > 0.0:
			kg_h = r
	var kg_m := maxf(float(specs.get("kg_per_m", DEFAULT_KG_PER_M)), 0.001)
	return kg_h / kg_m


static func mass_kg_for_length(length_m: float, specs: Dictionary) -> float:
	return maxf(length_m, 0.0) * maxf(float(specs.get("kg_per_m", DEFAULT_KG_PER_M)), 0.0)


## Advance extrusion over `dt_hours` of sim time while RUNNING.
## Returns {extruded_length_m, beams_cut, cut_mass_kg, meters_per_hour}.
static func advance(specs: Dictionary, dt_hours: float, running: bool) -> Dictionary:
	var length := maxf(float(specs.get("extruded_length_m", 0.0)), 0.0)
	var cut_len := maxf(float(specs.get("cut_length_m", DEFAULT_CUT_LENGTH_M)), 0.05)
	var mph := meters_per_hour(specs)
	var beams := 0
	var cut_mass := 0.0
	if running and dt_hours > 0.0:
		length += mph * dt_hours
		while length + 1e-9 >= cut_len:
			length -= cut_len
			beams += 1
			cut_mass += mass_kg_for_length(cut_len, specs)
	elif not running and dt_hours > 0.0:
		pass  # hold length while idle (die is parked)
	return {
		"extruded_length_m": length,
		"beams_cut": beams,
		"cut_mass_kg": cut_mass,
		"meters_per_hour": mph,
		"cut_length_m": cut_len,
		"fill_fraction": clampf(length / cut_len, 0.0, 1.0),
	}
