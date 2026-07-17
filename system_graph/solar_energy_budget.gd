class_name SolarEnergyBudget
extends RefCounted

## Educational site-level solar budget: SoI incoming flux vs what panels and
## grow beds are currently capturing. Numbers are instantaneous (kW), not
## daily integrals — meant for the System Review / inspector, not scoring.

## Approximate chemical energy in dry biomass (MJ/kg). Lower heating value for
## herbaceous dry matter is ~15–18 MJ/kg (IPCC / biomass fuel tables); we use
## 16 MJ/kg so plant “captured” chemical power can be compared to PAR/PV kW.
const BIOMASS_MJ_PER_KG := 16.0


## Snapshot from a live GraphModel.
## Returns {
##   flux_kw, irradiance_wm2, cloud_frac, sun_availability,
##   panel_kw, plant_par_kw, plant_chem_kw,
##   capture_kw, efficiency_pct, has_pbi
## }
static func compute(model: GraphModel) -> Dictionary:
	var out := {
		"flux_kw": 0.0,
		"irradiance_wm2": 0.0,
		"cloud_frac": 0.0,
		"sun_availability": 0.0,
		"panel_kw": 0.0,
		"plant_par_kw": 0.0,
		"plant_chem_kw": 0.0,
		"capture_kw": 0.0,
		"efficiency_pct": 0.0,
		"has_pbi": false,
		"panel_count": 0,
		"plant_count": 0,
	}
	if model == null:
		return out
	for item: Dictionary in model.items:
		if bool(item.get("is_virtual", false)):
			continue
		var ty := str(item.get("type", ""))
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if ty == "pbi":
			var kind := ResourceKinds.normalize_kind(str(specs.get("resource_kind", "")))
			if kind == "sunlight" or kind == "solar":
				out["has_pbi"] = true
				out["flux_kw"] = float(specs.get("flux_kw", 0.0))
				out["irradiance_wm2"] = float(specs.get("irradiance_wm2", 0.0))
				out["cloud_frac"] = float(specs.get("cloud_frac", 0.0))
				out["sun_availability"] = float(specs.get("sun_availability", 0.0))
		elif ty == "panel":
			out["panel_count"] = int(out["panel_count"]) + 1
			out["panel_kw"] = float(out["panel_kw"]) + maxf(0.0, float(specs.get("current_output_kw", 0.0)))
		elif ty == "plant":
			out["plant_count"] = int(out["plant_count"]) + 1
			var par := float(specs.get("par_wm2", 0.0))
			var area := float(specs.get("area_m2_effective", specs.get("area_m2", 0.0)))
			var sun_f := PlantGrowth.sunlight_factor_from_specs(specs)
			# Incident PAR power on the bed (kW) after shade.
			out["plant_par_kw"] = float(out["plant_par_kw"]) + maxf(0.0, par * area * sun_f / 1000.0)
			var bio_kg_h := float(specs.get("biomass_kg_h", 0.0))
			# Chemical power locked into biomass (kW): kg/h × MJ/kg / 3.6
			out["plant_chem_kw"] = float(out["plant_chem_kw"]) \
					+ maxf(0.0, bio_kg_h) * BIOMASS_MJ_PER_KG / 3.6

	var capture: float = float(out["panel_kw"]) + float(out["plant_chem_kw"])
	out["capture_kw"] = capture
	var flux: float = float(out["flux_kw"])
	if flux > 0.001:
		out["efficiency_pct"] = clampf(capture / flux * 100.0, 0.0, 100.0)
	return out


## Human-readable flux string matching PBI display conventions.
static func format_kw(kw: float) -> String:
	if kw >= 1000.0:
		return "%.2f MW" % (kw / 1000.0)
	if kw >= 1.0:
		return "%.1f kW" % kw
	if kw >= 0.001:
		return "%.0f W" % (kw * 1000.0)
	return "0 W"
