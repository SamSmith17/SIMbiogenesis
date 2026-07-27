class_name HydroSectionCalculator
extends RefCounted

## Pure hydropower / pipe readout for the Elevation Hydro Section panel.
## Combines pond stage + culvert bank Q with optional HydroSource penstock math.

const WATER_DENSITY := 1000.0
const G := 9.80665


## Build a snapshot from pond tank specs + culvert connection dicts.
## `culverts` entries: invert_in_m, invert_out_m, diameter_m, length_m, manning_n.
## Optional `hydro_specs` from a graph hydro item for generation mode.
## `month` (1–12) selects the seasonal flow multiplier for the generation estimate
## (was hardwired to June); callers thread the live sim month.
static func evaluate(pond_level_m: float, culverts: Array,
		hydro_specs: Dictionary = {}, outlet_elev_m: float = NAN,
		month: int = 6) -> Dictionary:
	var bank := CulvertHydraulics.stage_discharge_bank(pond_level_m, culverts)
	var q_m3s := float(bank.get("q_m3s", 0.0))
	var q_lps := float(bank.get("q_lps", 0.0))
	var out_elev := outlet_elev_m
	if is_nan(out_elev) and not culverts.is_empty():
		out_elev = INF
		for c in culverts:
			if c is Dictionary:
				out_elev = minf(out_elev, float((c as Dictionary).get("invert_out_m", INF)))
		if out_elev == INF:
			out_elev = pond_level_m
	var gross_head := maxf(pond_level_m - out_elev, 0.0)
	var pe_kw := WATER_DENSITY * G * q_m3s * gross_head / 1000.0
	var result := {
		"pond_level_m": pond_level_m,
		"gross_head_m": gross_head,
		"outlet_elev_m": out_elev,
		"design_flow_lps": q_lps,
		"live_q_lps": q_lps,
		"live_q_m3s": q_m3s,
		"pe_kw": pe_kw,
		"kwh_per_day": pe_kw * 24.0,
		"open_count": int(bank.get("open_count", 0)),
		"culvert_count": culverts.size(),
		"bank": bank,
		"mode": "potential",
		"gen_kw": 0.0,
		"net_head_m": gross_head,
		"head_loss_m": 0.0,
	}
	if hydro_specs.is_empty():
		return result
	# Generation mode: feed live Q/head into HydroSource graph adapter.
	var specs: Dictionary = hydro_specs.duplicate(true)
	if not bool(specs.get("lock_gross_head", false)):
		specs["gross_head_m"] = gross_head
	if not bool(specs.get("lock_design_flow", false)):
		specs["design_flow_lps"] = maxf(q_lps, 0.01)
	var gen := HydroSource.power_kw_from_graph_specs(specs, clampi(month, 1, 12))
	result["mode"] = "generation"
	result["gen_kw"] = gen
	result["gross_head_m"] = float(specs.get("gross_head_m", gross_head))
	result["design_flow_lps"] = float(specs.get("design_flow_lps", q_lps))
	# Friction loss when penstock specs present.
	var q_design := float(specs.get("design_flow_lps", q_lps)) / 1000.0
	var d_mm := float(specs.get("penstock_diameter_mm", 0.0))
	var L := float(specs.get("penstock_length_m", 0.0))
	if d_mm > 1.0 and L > 0.1 and q_design > 0.0:
		var rough := maxf(float(specs.get("pipe_roughness_mm", 0.0015)), 0.0) / 1000.0
		var hf := HydroSource.pipe_friction_head_loss_m(
			q_design, d_mm / 1000.0, L, rough)
		result["head_loss_m"] = hf
		result["net_head_m"] = maxf(float(specs.get("gross_head_m", gross_head)) - hf, 0.0)
	return result


## Collect culvert hydraulics dicts from a GraphModel (+ optional pond tag filter).
static func culverts_from_model(model: GraphModel, pond_tag: String = "") -> Array:
	var out: Array = []
	if model == null:
		return out
	for conn in model.connections:
		if not (conn is Dictionary):
			continue
		var c: Dictionary = conn
		var type_id := ConduitKinds.derive_type_for_connection(c)
		if not ConduitKinds.uses_culvert_kit(type_id):
			continue
		var meta := ConduitKinds.type_meta(type_id)
		var hs := CulvertHydraulics.specs_from_connection(c, meta)
		if not pond_tag.is_empty() and str(hs.get("inlet_pond_tag", "")) != pond_tag \
				and str(hs.get("inlet_pond_tag", "")) != "":
			# Soft filter: include untagged culverts from this pond's source.
			pass
		if is_nan(float(hs.get("invert_in_m", NAN))) \
				or is_nan(float(hs.get("invert_out_m", NAN))):
			continue
		out.append(hs)
	return out


## Find the primary pond_storage tank on the model (optional tag).
## Prefers tanks with usable floor/rim (or level_m) over null-bathymetry twins.
static func find_pond_tank(model: GraphModel, pond_tag: String = "") -> Dictionary:
	if model == null:
		return {}
	var fallback: Dictionary = {}
	for it in model.items:
		if not (it is Dictionary):
			continue
		var tank: Dictionary = it
		var specs: Dictionary = tank.get("specs", {}) as Dictionary
		if not bool(specs.get("pond_storage", false)):
			continue
		if bool(specs.get("outlet_sink", false)):
			continue
		if not pond_tag.is_empty() \
				and str(specs.get("osm_water_tag", "")) != pond_tag:
			continue
		var floor_m := float(specs.get("floor_m", NAN))
		var rim_m := float(specs.get("rim_m", NAN))
		var level_m := float(specs.get("level_m", NAN))
		var usable := (not is_nan(level_m)) \
				or (not is_nan(floor_m) and not is_nan(rim_m) and rim_m > floor_m + 0.05)
		if usable:
			return tank
		if fallback.is_empty():
			fallback = tank
	return fallback


static func pond_level_m_from_tank(tank: Dictionary) -> float:
	var specs: Dictionary = tank.get("specs", {}) as Dictionary
	var level_m := float(specs.get("level_m", NAN))
	if not is_nan(level_m):
		return level_m
	var rim := float(specs.get("rim_m", NAN))
	var floor_y := float(specs.get("floor_m", NAN))
	if not is_nan(rim) and not is_nan(floor_y):
		return floor_y + clampf(float(specs.get("level", 0.0)), 0.0, 1.0) \
				* maxf(rim - floor_y, 0.05)
	return NAN
